-- Carga de la Division Politico Administrativa (DPA) 2023 en el modelo.
--
-- Requisito: scripts/load_dpa_postgis.ps1 ya importo los tres shapefiles
-- oficiales con shp2pgsql al esquema temporal dpa_staging, sin reproyectar
-- (SRID 5360, SIRGAS-Chile 2002, coordenadas geograficas):
--   dpa_staging.regiones   (cut_reg, region, superficie, geom)
--   dpa_staging.provincias (cut_reg, cut_prov, region, provincia, superficie, geom)
--   dpa_staging.comunas    (cut_reg, cut_prov, cut_com, region, provincia, comuna, superficie, geom)
--
-- Que hace este archivo, en una sola transaccion:
--   1. Registra la carga en seismic.ingestion_run (fuente 'dpa').
--   2. Reproyecta SIRGAS-Chile (5360) -> WGS 84 (4326), repara geometrias
--      invalidas y fuerza MultiPolygon.
--   3. Inserta o actualiza (UPSERT) regiones, provincias y comunas,
--      enlazando cada nivel con su padre (comuna -> provincia -> region).
--   4. Regenera los trozos de comuna (ST_Subdivide) usados para acelerar
--      la asignacion punto-en-poligono.
--   5. Elimina el esquema temporal dpa_staging.
--
-- Es idempotente: ejecutarlo dos veces deja el mismo resultado.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

BEGIN;

-- 0. Controles previos: un registro por codigo oficial en cada nivel.
DO $$
DECLARE
    duplicated integer;
BEGIN
    SELECT count(*) INTO duplicated FROM (
        SELECT cut_reg FROM dpa_staging.regiones GROUP BY cut_reg HAVING count(*) > 1
        UNION ALL
        SELECT cut_prov FROM dpa_staging.provincias GROUP BY cut_prov HAVING count(*) > 1
        UNION ALL
        SELECT cut_com FROM dpa_staging.comunas GROUP BY cut_com HAVING count(*) > 1
    ) AS duplicates;
    IF duplicated > 0 THEN
        RAISE EXCEPTION 'La DPA trae % codigos oficiales repetidos', duplicated;
    END IF;
END
$$;

-- 1. Auditoria de la carga.
INSERT INTO seismic.ingestion_run (source_code, received_events, status, details)
SELECT
    'dpa',
    (SELECT count(*) FROM dpa_staging.regiones)
        + (SELECT count(*) FROM dpa_staging.provincias)
        + (SELECT count(*) FROM dpa_staging.comunas),
    'running',
    jsonb_build_object(
        'dataset', 'DPA 2023 v1 (SUBDERE / IDE Chile, publicada 2023-08-03)',
        'source_srid', 5360,
        'target_srid', 4326,
        'regions', (SELECT count(*) FROM dpa_staging.regiones),
        'provinces', (SELECT count(*) FROM dpa_staging.provincias),
        'communes', (SELECT count(*) FROM dpa_staging.comunas),
        'note', 'received_events cuenta poligonos administrativos, no sismos'
    )
RETURNING ingestion_run_id AS dpa_ingestion_run_id \gset

CREATE TEMP TABLE existing_areas AS
SELECT level, official_code FROM seismic.administrative_area;

-- Funcion auxiliar de limpieza geometrica (solo para esta sesion):
--   ST_Transform    : SIRGAS-Chile -> WGS 84 (diferencia submetrica).
--   ST_MakeValid    : repara anillos autointersectados, si los hubiera.
--   ST_CollectionExtract(..., 3): conserva solo poligonos.
--   ST_Multi        : la columna exige MultiPolygon.
CREATE FUNCTION pg_temp.clean_area(source geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE AS $$
    SELECT ST_Multi(
        ST_CollectionExtract(ST_MakeValid(ST_Transform(source, 4326)), 3)
    )
$$;

-- 2. Regiones (sin padre).
INSERT INTO seismic.administrative_area (
    level, official_code, name, source, source_version,
    official_area_km2, parent_area_id, geom, loaded_at
)
SELECT
    'region',
    cut_reg,
    region,
    'SUBDERE DPA 2023',
    'DPA 2023 v1',
    superficie,
    NULL,
    pg_temp.clean_area(geom),
    now()
FROM dpa_staging.regiones
ON CONFLICT (level, official_code) DO UPDATE SET
    name = EXCLUDED.name,
    source = EXCLUDED.source,
    source_version = EXCLUDED.source_version,
    official_area_km2 = EXCLUDED.official_area_km2,
    parent_area_id = EXCLUDED.parent_area_id,
    geom = EXCLUDED.geom,
    loaded_at = EXCLUDED.loaded_at;

-- 3. Provincias (padre = region con el mismo cut_reg).
INSERT INTO seismic.administrative_area (
    level, official_code, name, source, source_version,
    official_area_km2, parent_area_id, geom, loaded_at
)
SELECT
    'province',
    staged.cut_prov,
    staged.provincia,
    'SUBDERE DPA 2023',
    'DPA 2023 v1',
    staged.superficie,
    parent.administrative_area_id,
    pg_temp.clean_area(staged.geom),
    now()
FROM dpa_staging.provincias AS staged
JOIN seismic.administrative_area AS parent
  ON parent.level = 'region'
 AND parent.official_code = staged.cut_reg
ON CONFLICT (level, official_code) DO UPDATE SET
    name = EXCLUDED.name,
    source = EXCLUDED.source,
    source_version = EXCLUDED.source_version,
    official_area_km2 = EXCLUDED.official_area_km2,
    parent_area_id = EXCLUDED.parent_area_id,
    geom = EXCLUDED.geom,
    loaded_at = EXCLUDED.loaded_at;

-- 4. Comunas (padre = provincia con el mismo cut_prov).
INSERT INTO seismic.administrative_area (
    level, official_code, name, source, source_version,
    official_area_km2, parent_area_id, geom, loaded_at
)
SELECT
    'commune',
    staged.cut_com,
    staged.comuna,
    'SUBDERE DPA 2023',
    'DPA 2023 v1',
    staged.superficie,
    parent.administrative_area_id,
    pg_temp.clean_area(staged.geom),
    now()
FROM dpa_staging.comunas AS staged
JOIN seismic.administrative_area AS parent
  ON parent.level = 'province'
 AND parent.official_code = staged.cut_prov
ON CONFLICT (level, official_code) DO UPDATE SET
    name = EXCLUDED.name,
    source = EXCLUDED.source,
    source_version = EXCLUDED.source_version,
    official_area_km2 = EXCLUDED.official_area_km2,
    parent_area_id = EXCLUDED.parent_area_id,
    geom = EXCLUDED.geom,
    loaded_at = EXCLUDED.loaded_at;

-- Control: ninguna provincia o comuna puede quedar sin padre, y no puede
-- quedar ninguna geometria vacia o invalida.
DO $$
DECLARE
    orphans integer;
    bad_geometries integer;
BEGIN
    SELECT count(*) INTO orphans
    FROM seismic.administrative_area
    WHERE level IN ('province', 'commune') AND parent_area_id IS NULL;
    IF orphans > 0 THEN
        RAISE EXCEPTION '% provincias/comunas quedaron sin area padre', orphans;
    END IF;

    SELECT count(*) INTO bad_geometries
    FROM seismic.administrative_area
    WHERE ST_IsEmpty(geom) OR NOT ST_IsValid(geom);
    IF bad_geometries > 0 THEN
        RAISE EXCEPTION '% areas con geometria vacia o invalida', bad_geometries;
    END IF;
END
$$;

-- 5. Trozos de comuna para consultas rapidas. ST_Subdivide corta cada
-- comuna en poligonos de hasta 255 vertices; ST_Dump separa las partes.
DELETE FROM seismic.administrative_area_part;

INSERT INTO seismic.administrative_area_part (administrative_area_id, geom)
SELECT
    area.administrative_area_id,
    dumped.geom
FROM seismic.administrative_area AS area
CROSS JOIN LATERAL ST_Subdivide(area.geom, 255) AS piece(geom)
CROSS JOIN LATERAL ST_Dump(piece.geom) AS dumped
WHERE area.level = 'commune'
  AND GeometryType(dumped.geom) = 'POLYGON';

-- 6. Cierre de la auditoria.
UPDATE seismic.ingestion_run
SET
    finished_at = now(),
    inserted_events = (
        SELECT count(*)
        FROM seismic.administrative_area AS area
        WHERE NOT EXISTS (
            SELECT 1 FROM existing_areas AS old
            WHERE old.level = area.level AND old.official_code = area.official_code
        )
    ),
    updated_events = (SELECT count(*) FROM existing_areas),
    status = 'completed',
    details = details || jsonb_build_object(
        'commune_parts', (SELECT count(*) FROM seismic.administrative_area_part)
    )
WHERE ingestion_run_id = :dpa_ingestion_run_id;

COMMIT;

DROP SCHEMA IF EXISTS dpa_staging CASCADE;

-- Una recarga reescribe todos los poligonos (UPSERT); VACUUM deja reutilizable
-- el espacio de las versiones anteriores para que la base no crezca en cada
-- recarga, y ANALYZE actualiza las estadisticas del planificador.
VACUUM (ANALYZE) seismic.administrative_area;
VACUUM (ANALYZE) seismic.administrative_area_part;

-- Resumen visible.
SELECT
    level,
    count(*) AS areas,
    round(sum(official_area_km2)) AS official_area_km2,
    sum(ST_NPoints(geom)) AS vertices
FROM seismic.administrative_area
GROUP BY level
ORDER BY CASE level WHEN 'region' THEN 1 WHEN 'province' THEN 2 ELSE 3 END;

SELECT count(*) AS commune_parts,
       max(ST_NPoints(geom)) AS max_vertices_per_part
FROM seismic.administrative_area_part;

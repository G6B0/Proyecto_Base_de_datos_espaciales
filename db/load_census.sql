-- Carga de la cartografia del Censo 2024 (INE) en el modelo.
--
-- Requisito: scripts/load_ine_manzanas_postgis.ps1 ya importo con ogr2ogr,
-- reproyectadas a EPSG:4326, las dos capas al esquema temporal ine_staging:
--   ine_staging.limite_urbano (cut, area_c, localidad, entidad, categoria,
--       id_entidad, conurbacion, n_per, n_edad_0_5, n_edad_60_mas,
--       n_discapacidad, n_hog, n_vp, n_mat_paredes_artesanal,
--       n_mat_paredes_precarios, geom)
--   ine_staging.manzanas      (cut, area_c, tipo_mz, manzent, id_entidad,
--       mz_base_censo, n_per, n_edad_60_mas, n_vp, n_mat_paredes_artesanal, geom)
-- Las cifras del INE vienen como numeros reales; los conteos se redondean a
-- enteros. Los valores anonimizados por secreto estadistico vienen NULL y se
-- conservan NULL (n_per nunca es NULL).
--
-- Que hace este archivo, en una sola transaccion:
--   1. Controles: codigos unicos y cada comuna del INE existe en la DPA.
--   2. Registra la carga en seismic.ingestion_run (fuente 'ine').
--   3. UPSERT de zonas urbanas por ID_ENTIDAD (sus ids se mantienen entre
--      recargas) y borra las que ya no vengan en el archivo.
--   4. Reemplaza todas las manzanas y las enlaza con su zona urbana.
--   5. Controla que la poblacion de las manzanas urbanas sume lo mismo que
--      la de las zonas urbanas.
--   6. Elimina el esquema temporal ine_staging.
--
-- Requiere la DPA cargada (scripts/load_dpa_postgis.ps1). Es idempotente.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

BEGIN;

-- 1. Controles previos.
DO $$
DECLARE
    problems integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM seismic.administrative_area WHERE level = 'commune') THEN
        RAISE EXCEPTION 'No hay comunas cargadas. Ejecuta primero scripts/load_dpa_postgis.ps1';
    END IF;

    SELECT count(*) INTO problems FROM (
        SELECT id_entidad FROM ine_staging.limite_urbano GROUP BY id_entidad HAVING count(*) > 1
    ) AS repeated;
    IF problems > 0 THEN
        RAISE EXCEPTION 'Limite_Urbano trae % ID_ENTIDAD repetidos', problems;
    END IF;

    SELECT count(*) INTO problems FROM (
        SELECT manzent FROM ine_staging.manzanas GROUP BY manzent HAVING count(*) > 1
    ) AS repeated;
    IF problems > 0 THEN
        RAISE EXCEPTION 'Manzanas trae % MANZENT repetidos', problems;
    END IF;

    -- El INE guarda el codigo de comuna como entero (1101); la DPA como
    -- texto de 5 digitos ('01101').
    SELECT count(DISTINCT staged.cut) INTO problems
    FROM (
        SELECT cut FROM ine_staging.limite_urbano
        UNION SELECT cut FROM ine_staging.manzanas
    ) AS staged
    LEFT JOIN seismic.administrative_area AS commune
           ON commune.level = 'commune'
          AND commune.official_code = lpad(staged.cut::text, 5, '0')
    WHERE commune.administrative_area_id IS NULL;
    IF problems > 0 THEN
        RAISE EXCEPTION '% codigos de comuna del INE no existen en la DPA', problems;
    END IF;
END
$$;

-- 2. Auditoria de la carga.
INSERT INTO seismic.ingestion_run (source_code, received_events, status, details)
SELECT
    'ine',
    (SELECT count(*) FROM ine_staging.limite_urbano)
        + (SELECT count(*) FROM ine_staging.manzanas),
    'running',
    jsonb_build_object(
        'dataset', 'Censo 2024 - Base Cartografica Censal, GeoParquet pais (INE, 2025-12-16)',
        'source_srid', 4674,
        'target_srid', 4326,
        'urban_areas', (SELECT count(*) FROM ine_staging.limite_urbano),
        'census_blocks', (SELECT count(*) FROM ine_staging.manzanas),
        'note', 'received_events cuenta poligonos censales, no sismos'
    )
RETURNING ingestion_run_id AS census_ingestion_run_id \gset

CREATE TEMP TABLE existing_urban_areas AS
SELECT ine_entity_id FROM seismic.urban_area;

-- Limpieza geometrica (solo para esta sesion): repara anillos invalidos,
-- conserva solo poligonos y fuerza MultiPolygon. Ya vienen en 4326.
CREATE FUNCTION pg_temp.clean_area(source geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE AS $$
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(source, 4326)), 3))
$$;

-- 3. Zonas urbanas (ciudades y pueblos).
INSERT INTO seismic.urban_area (
    ine_entity_id, name, category, locality_name, conurbation, commune_area_id,
    population, population_0_5, population_60_plus, population_disability,
    households, private_dwellings, dwellings_adobe, dwellings_precarious,
    area_km2, source_version, loaded_at, geom
)
SELECT
    staged.id_entidad::bigint,
    staged.entidad,
    lower(staged.categoria),
    staged.localidad,
    nullif(btrim(staged.conurbacion), ''),
    commune.administrative_area_id,
    round(staged.n_per)::integer,
    round(staged.n_edad_0_5)::integer,
    round(staged.n_edad_60_mas)::integer,
    round(staged.n_discapacidad)::integer,
    round(staged.n_hog)::integer,
    round(staged.n_vp)::integer,
    round(staged.n_mat_paredes_artesanal)::integer,
    round(staged.n_mat_paredes_precarios)::integer,
    round((ST_Area(pg_temp.clean_area(staged.geom)::geography) / 1e6)::numeric, 3),
    'Censo 2024 (INE, 2025-12-16)',
    now(),
    pg_temp.clean_area(staged.geom)
FROM ine_staging.limite_urbano AS staged
JOIN seismic.administrative_area AS commune
  ON commune.level = 'commune'
 AND commune.official_code = lpad(staged.cut::text, 5, '0')
ON CONFLICT (ine_entity_id) DO UPDATE SET
    name = EXCLUDED.name,
    category = EXCLUDED.category,
    locality_name = EXCLUDED.locality_name,
    conurbation = EXCLUDED.conurbation,
    commune_area_id = EXCLUDED.commune_area_id,
    population = EXCLUDED.population,
    population_0_5 = EXCLUDED.population_0_5,
    population_60_plus = EXCLUDED.population_60_plus,
    population_disability = EXCLUDED.population_disability,
    households = EXCLUDED.households,
    private_dwellings = EXCLUDED.private_dwellings,
    dwellings_adobe = EXCLUDED.dwellings_adobe,
    dwellings_precarious = EXCLUDED.dwellings_precarious,
    area_km2 = EXCLUDED.area_km2,
    source_version = EXCLUDED.source_version,
    loaded_at = EXCLUDED.loaded_at,
    geom = EXCLUDED.geom;

-- Zonas urbanas que ya no vienen en el archivo (sus vinculos con sismos se
-- borran en cascada y se recalculan con db/assign_urban_exposure.sql).
DELETE FROM seismic.urban_area AS area
WHERE NOT EXISTS (
    SELECT 1 FROM ine_staging.limite_urbano AS staged
    WHERE staged.id_entidad::bigint = area.ine_entity_id
);

-- Trozos de zona urbana para medir distancias rapido (ST_Subdivide corta
-- cada zona en poligonos de hasta 255 vertices; ST_Dump separa las partes).
DELETE FROM seismic.urban_area_part;

INSERT INTO seismic.urban_area_part (urban_area_id, geom)
SELECT
    area.urban_area_id,
    dumped.geom
FROM seismic.urban_area AS area
CROSS JOIN LATERAL ST_Subdivide(area.geom, 255) AS piece(geom)
CROSS JOIN LATERAL ST_Dump(piece.geom) AS dumped
WHERE GeometryType(dumped.geom) = 'POLYGON';

-- 4. Manzanas: se reemplazan completas (nada las referencia).
TRUNCATE seismic.census_block;

INSERT INTO seismic.census_block (
    block_code, block_type, urban_area_id, commune_area_id, has_census_data,
    population, population_60_plus, private_dwellings, dwellings_adobe,
    point, geom
)
SELECT
    staged.manzent::bigint,
    lower(staged.tipo_mz),
    urban.urban_area_id,
    commune.administrative_area_id,
    staged.mz_base_censo = 1,
    round(staged.n_per)::integer,
    round(staged.n_edad_60_mas)::integer,
    round(staged.n_vp)::integer,
    round(staged.n_mat_paredes_artesanal)::integer,
    ST_PointOnSurface(cleaned.geom),
    cleaned.geom
FROM ine_staging.manzanas AS staged
CROSS JOIN LATERAL (SELECT pg_temp.clean_area(staged.geom) AS geom) AS cleaned
JOIN seismic.administrative_area AS commune
  ON commune.level = 'commune'
 AND commune.official_code = lpad(staged.cut::text, 5, '0')
LEFT JOIN seismic.urban_area AS urban
       ON lower(staged.tipo_mz) = 'urbano'
      AND urban.ine_entity_id = staged.id_entidad::bigint;

-- 5. Controles posteriores.
DO $$
DECLARE
    staged_blocks bigint;
    loaded_blocks bigint;
    urban_population bigint;
    block_population bigint;
    bad_geometries integer;
BEGIN
    SELECT count(*) INTO staged_blocks FROM ine_staging.manzanas;
    SELECT count(*) INTO loaded_blocks FROM seismic.census_block;
    IF staged_blocks <> loaded_blocks THEN
        RAISE EXCEPTION 'Se esperaban % manzanas y se cargaron %', staged_blocks, loaded_blocks;
    END IF;

    SELECT sum(population) INTO urban_population FROM seismic.urban_area;
    SELECT sum(population) INTO block_population
    FROM seismic.census_block WHERE block_type = 'urbano';
    IF urban_population <> block_population THEN
        RAISE EXCEPTION 'Poblacion de zonas urbanas (%) distinta a la de sus manzanas (%)',
            urban_population, block_population;
    END IF;

    SELECT count(*) INTO bad_geometries
    FROM (
        SELECT geom FROM seismic.urban_area
        UNION ALL SELECT geom FROM seismic.census_block
    ) AS shapes
    WHERE ST_IsEmpty(geom) OR NOT ST_IsValid(geom);
    IF bad_geometries > 0 THEN
        RAISE EXCEPTION '% geometrias censales vacias o invalidas', bad_geometries;
    END IF;
END
$$;

-- 6. Cierre de la auditoria.
UPDATE seismic.ingestion_run
SET
    finished_at = now(),
    inserted_events = (
        SELECT count(*) FROM seismic.urban_area AS area
        WHERE NOT EXISTS (
            SELECT 1 FROM existing_urban_areas AS old
            WHERE old.ine_entity_id = area.ine_entity_id
        )
    ),
    updated_events = (SELECT count(*) FROM existing_urban_areas),
    status = 'completed',
    details = details || jsonb_build_object(
        'urban_area_parts', (SELECT count(*) FROM seismic.urban_area_part),
        'population_urban', (SELECT sum(population) FROM seismic.urban_area),
        'population_in_blocks', (SELECT sum(population) FROM seismic.census_block)
    )
WHERE ingestion_run_id = :census_ingestion_run_id;

COMMIT;

SET client_min_messages TO warning;
DROP SCHEMA IF EXISTS ine_staging CASCADE;
RESET client_min_messages;

VACUUM (ANALYZE) seismic.urban_area;
VACUUM (ANALYZE) seismic.urban_area_part;
VACUUM (ANALYZE) seismic.census_block;

-- Resumen visible.
SELECT
    category,
    count(*) AS urban_areas,
    sum(population) AS population,
    round(sum(area_km2)) AS area_km2
FROM seismic.urban_area
GROUP BY category
ORDER BY category;

SELECT
    block_type,
    count(*) AS census_blocks,
    count(*) FILTER (WHERE has_census_data) AS with_data,
    sum(population) AS population
FROM seismic.census_block
GROUP BY block_type
ORDER BY block_type;

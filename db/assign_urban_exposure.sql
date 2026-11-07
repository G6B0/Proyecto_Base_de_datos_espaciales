-- Zonas urbanas y poblacion cerca de cada sismo (Censo 2024).
--
-- Reglas (docs/INE_CENSO2024.md y docs/MODELO_LOGICO_v2.md):
--   seismic.event_urban_area
--     a. Todo sismo guarda su zona urbana mas cercana (distance_rank = 1).
--     b. Los sismos con Mw homogeneo >= 5 guardan ademas todas las zonas
--        urbanas a 200 km o menos del epicentro, numeradas por distancia.
--     La distancia es geodesica (metros sobre el elipsoide) desde el
--     epicentro hasta el BORDE de la zona urbana: 0 si cae dentro.
--     hypocentral_distance_km agrega la profundidad:
--         sqrt(distancia_epicentral^2 + profundidad^2)
--     y es la que mejor se relaciona con cuanto se siente un sismo.
--   seismic.event_population_exposure
--     Para cada sismo con Mw >= 5: personas y viviendas de las manzanas cuyo
--     punto interior esta a 25, 50 y 100 km del epicentro. Es poblacion que
--     vive cerca, no una estimacion de dano ni de intensidad.
--
-- Dos modos, siempre dentro de una transaccion (si algo falla, el calculo
-- anterior queda intacto):
--   completo    (por defecto): borra y recalcula todo. ~6 min. Lo usa
--               scripts/load_ine_manzanas_postgis.ps1 al cargar el censo.
--       psql ... -f db/assign_urban_exposure.sql
--   incremental (-v incremental=1): solo calcula los sismos sin resultado
--               (nuevos) y los que llegaron a Mw >= 5 sin poblacion
--               calculada; limpia los que bajaron de Mw 5. Segundos. Lo usa
--               scripts/load_catalogs_postgis.ps1 despues de cada carga.
--       psql ... -v incremental=1 -f db/assign_urban_exposure.sql
--   El modo incremental NO detecta un sismo ya calculado al que la fuente le
--   cambio la ubicacion; para eso se ejecuta el modo completo.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- Parametros de la regla.
\set exposure_min_mw 5.0
\set exposure_radius_m 200000

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM seismic.urban_area_part) THEN
        RAISE EXCEPTION 'No hay zonas urbanas cargadas. Ejecuta primero scripts/load_ine_manzanas_postgis.ps1';
    END IF;
END
$$;

-- Sismos a calcular en esta ejecucion.
CREATE TEMP TABLE target (
    earthquake_event_id bigint PRIMARY KEY
) ON COMMIT DROP;

\if :{?incremental}
-- Sismos que bajaron de Mw 5 (o perdieron su Mw): se borra su poblacion y
-- sus zonas a 200 km; conservan su zona mas cercana.
DELETE FROM seismic.event_population_exposure AS exposure
USING seismic.earthquake_event AS event
WHERE event.earthquake_event_id = exposure.earthquake_event_id
  AND (event.mw_homogenized IS NULL OR event.mw_homogenized < :exposure_min_mw);

DELETE FROM seismic.event_urban_area AS link
USING seismic.earthquake_event AS event
WHERE event.earthquake_event_id = link.earthquake_event_id
  AND link.distance_rank > 1
  AND (event.mw_homogenized IS NULL OR event.mw_homogenized < :exposure_min_mw);

INSERT INTO target
SELECT event.earthquake_event_id
FROM seismic.earthquake_event AS event
WHERE NOT EXISTS (
        SELECT 1 FROM seismic.event_urban_area AS link
        WHERE link.earthquake_event_id = event.earthquake_event_id
    )
   OR (event.mw_homogenized >= :exposure_min_mw
       AND NOT EXISTS (
           SELECT 1 FROM seismic.event_population_exposure AS exposure
           WHERE exposure.earthquake_event_id = event.earthquake_event_id
       ));

DELETE FROM seismic.event_urban_area AS link
USING target
WHERE target.earthquake_event_id = link.earthquake_event_id;
\else
TRUNCATE seismic.event_urban_area, seismic.event_population_exposure;

INSERT INTO target
SELECT earthquake_event_id FROM seismic.earthquake_event;
\endif

ANALYZE target;

-- Candidatos: (a) la zona mas cercana de cada sismo y (b) todas las zonas a
-- 200 km de los sismos Mw >= 5.
CREATE TEMP TABLE candidate (
    earthquake_event_id bigint NOT NULL,
    urban_area_id bigint NOT NULL,
    distance_m double precision NOT NULL
) ON COMMIT DROP;

-- Ambos pasos miden contra los trozos de zona urbana (urban_area_part, de
-- hasta 255 vertices), no contra los poligonos completos: la distancia a una
-- zona es la menor distancia a cualquiera de sus trozos.
--
-- Medir la distancia de un punto a un poligono sobre geography (elipsoide)
-- es caro; midiendo exacto todos los trozos cercanos el calculo completo
-- tardaba 20 minutos. Por eso se mide en dos etapas:
--   1. Aproximada y barata: ST_ClosestPoint busca, en el plano, el punto del
--      trozo mas cercano al epicentro, y solo se mide sobre el elipsoide la
--      distancia entre esos DOS PUNTOS. Ese punto esta sobre el trozo, asi
--      que la aproximada NUNCA es menor que la exacta; en las pruebas se
--      alejo de ella en promedio 4 m y como maximo 0,4 km.
--   2. Exacta: ST_Distance sobre geography, pero solo contra los trozos cuya
--      aproximada esta a menos de 2 km (approx_margin_m) de la mejor.
--      Como aproximada >= exacta y el error es < margen, el trozo con la
--      menor distancia exacta siempre queda entre los medidos.
-- Verificado el 2026-11-07 contra el calculo exacto completo: mismos
-- vinculos, mismas distancias al metro y mismo orden (docs/INE_CENSO2024.md).
\set approx_margin_m 2000

CREATE FUNCTION pg_temp.approx_distance_m(part geometry, epicentre geometry)
RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
    SELECT ST_Distance(ST_ClosestPoint(part, epicentre)::geography, epicentre::geography)
$$;

-- (a) El operador <-> usa el indice GiST para traer los 10 trozos mas
-- cercanos en grados (un grado de longitud mide menos km en el sur que en el
-- norte, por eso no basta con el primero). Entre ellos se mide exacto los que
-- estan dentro del margen y se elige el menor.
INSERT INTO candidate
SELECT
    event.earthquake_event_id,
    best.urban_area_id,
    best.distance_m
FROM seismic.earthquake_event AS event
JOIN target USING (earthquake_event_id)
CROSS JOIN LATERAL (
    SELECT
        approx.urban_area_id,
        ST_Distance(approx.geom::geography, event.geom::geography) AS distance_m
    FROM (
        SELECT
            nearby.urban_area_id,
            nearby.geom,
            pg_temp.approx_distance_m(nearby.geom, event.geom) AS approx_m,
            min(pg_temp.approx_distance_m(nearby.geom, event.geom)) OVER () AS best_approx_m
        FROM (
            SELECT part.urban_area_id, part.geom
            FROM seismic.urban_area_part AS part
            ORDER BY part.geom <-> event.geom
            LIMIT 10
        ) AS nearby
    ) AS approx
    WHERE approx.approx_m <= approx.best_approx_m + :approx_margin_m
    ORDER BY distance_m, approx.urban_area_id
    LIMIT 1
) AS best;

-- (b) Prefiltro con el indice GiST de los trozos: una caja de 200 km
-- alrededor del epicentro, con los grados de longitud corregidos por la
-- latitud (se usa la latitud 2 grados mas al polo para no quedarse corto).
CREATE TEMP TABLE part_approx ON COMMIT DROP AS
SELECT
    event.earthquake_event_id,
    part.urban_area_id,
    part.geom AS part_geom,
    event.geom AS event_geom,
    pg_temp.approx_distance_m(part.geom, event.geom) AS approx_m
FROM seismic.earthquake_event AS event
JOIN target USING (earthquake_event_id)
JOIN seismic.urban_area_part AS part
  ON part.geom && ST_Expand(
         event.geom,
         :exposure_radius_m / (111320 * cos(radians(least(abs(ST_Y(event.geom)) + 2, 85))))
     )
WHERE event.mw_homogenized >= :exposure_min_mw;

-- Por cada par sismo-zona se miden exacto los trozos dentro del margen de la
-- mejor aproximada, y solo si la zona puede estar a 200 km o menos.
INSERT INTO candidate
SELECT earthquake_event_id, urban_area_id, min(distance_m)
FROM (
    SELECT
        earthquake_event_id,
        urban_area_id,
        ST_Distance(part_geom::geography, event_geom::geography) AS distance_m
    FROM (
        SELECT
            *,
            min(approx_m) OVER (PARTITION BY earthquake_event_id, urban_area_id) AS best_approx_m
        FROM part_approx
    ) AS ranked
    WHERE best_approx_m <= :exposure_radius_m + :approx_margin_m
      AND approx_m <= best_approx_m + :approx_margin_m
) AS measured
GROUP BY earthquake_event_id, urban_area_id
HAVING min(distance_m) <= :exposure_radius_m;

INSERT INTO seismic.event_urban_area (
    earthquake_event_id, urban_area_id, distance_rank,
    epicentral_distance_km, hypocentral_distance_km
)
SELECT
    ranked.earthquake_event_id,
    ranked.urban_area_id,
    row_number() OVER (
        PARTITION BY ranked.earthquake_event_id
        ORDER BY ranked.distance_m, ranked.urban_area_id
    ),
    round((ranked.distance_m / 1000)::numeric, 3),
    CASE WHEN event.depth_km IS NOT NULL THEN
        round(sqrt((ranked.distance_m / 1000) ^ 2
                   + greatest(event.depth_km, 0)::double precision ^ 2)::numeric, 3)
    END
FROM (
    SELECT DISTINCT ON (earthquake_event_id, urban_area_id)
        earthquake_event_id, urban_area_id, distance_m
    FROM candidate
    ORDER BY earthquake_event_id, urban_area_id, distance_m
) AS ranked
JOIN seismic.earthquake_event AS event
  ON event.earthquake_event_id = ranked.earthquake_event_id;

-- Poblacion expuesta. El indice census_block_point_geog_gix resuelve el
-- ST_DWithin de 100 km; los anillos de 25 y 50 km se filtran despues. Es el
-- paso mas caro del modo completo (~3,5 min): son decenas de millones de pares
-- manzana-sismo. Medir sobre la esfera en vez del elipsoide cambiaba los
-- conteos, por eso no se usa.
DELETE FROM seismic.event_population_exposure AS exposure
USING target
WHERE target.earthquake_event_id = exposure.earthquake_event_id;

INSERT INTO seismic.event_population_exposure (
    earthquake_event_id, population_25km, population_50km, population_100km,
    population_60_plus_50km, dwellings_adobe_50km, urban_areas_50km
)
SELECT
    event.earthquake_event_id,
    coalesce(sum(block.population) FILTER (WHERE block.distance_m <= 25000), 0),
    coalesce(sum(block.population) FILTER (WHERE block.distance_m <= 50000), 0),
    coalesce(sum(block.population), 0),
    coalesce(sum(block.population_60_plus) FILTER (WHERE block.distance_m <= 50000), 0),
    coalesce(sum(block.dwellings_adobe) FILTER (WHERE block.distance_m <= 50000), 0),
    (
        SELECT count(*)
        FROM seismic.event_urban_area AS link
        WHERE link.earthquake_event_id = event.earthquake_event_id
          AND link.epicentral_distance_km <= 50
    )
FROM seismic.earthquake_event AS event
JOIN target USING (earthquake_event_id)
LEFT JOIN LATERAL (
    SELECT
        census.population,
        census.population_60_plus,
        census.dwellings_adobe,
        ST_Distance(census.point::geography, event.geom::geography) AS distance_m
    FROM seismic.census_block AS census
    WHERE census.population > 0
      AND ST_DWithin(census.point::geography, event.geom::geography, 100000)
) AS block ON true
WHERE event.mw_homogenized >= :exposure_min_mw
GROUP BY event.earthquake_event_id;

-- Controles: todo sismo tiene su zona urbana mas cercana, y todo sismo
-- Mw >= 5 tiene su poblacion calculada.
DO $$
DECLARE
    missing_nearest bigint;
    missing_exposure bigint;
BEGIN
    SELECT count(*) INTO missing_nearest
    FROM seismic.earthquake_event AS event
    WHERE NOT EXISTS (
        SELECT 1 FROM seismic.event_urban_area AS link
        WHERE link.earthquake_event_id = event.earthquake_event_id
          AND link.distance_rank = 1
    );
    IF missing_nearest > 0 THEN
        RAISE EXCEPTION '% sismos quedaron sin zona urbana mas cercana', missing_nearest;
    END IF;

    SELECT count(*) INTO missing_exposure
    FROM seismic.earthquake_event AS event
    WHERE event.mw_homogenized >= 5
      AND NOT EXISTS (
          SELECT 1 FROM seismic.event_population_exposure AS exposure
          WHERE exposure.earthquake_event_id = event.earthquake_event_id
      );
    IF missing_exposure > 0 THEN
        RAISE EXCEPTION '% sismos Mw >= 5 quedaron sin poblacion calculada', missing_exposure;
    END IF;
END
$$;

SELECT count(*) AS events_computed_now FROM target;

COMMIT;

ANALYZE seismic.event_urban_area;
ANALYZE seismic.event_population_exposure;

-- Resumen visible.
SELECT
    count(DISTINCT earthquake_event_id) AS events,
    count(*) AS event_urban_links,
    count(*) FILTER (WHERE distance_rank = 1 AND epicentral_distance_km = 0) AS epicentre_inside_urban_area,
    round(avg(epicentral_distance_km) FILTER (WHERE distance_rank = 1), 1) AS avg_km_to_nearest
FROM seismic.event_urban_area;

SELECT
    count(*) AS events_mw5,
    sum((population_25km > 0)::int) AS with_population_25km,
    max(population_100km) AS max_population_100km
FROM seismic.event_population_exposure;

-- Validacion de la formula provisional Ml/Mlv -> Mw del CSN.
-- Explicacion y resultados en docs/MAGNITUDES.md (seccion 10).
--
-- Requisito: scripts/validate_ml_conversion.py ya descargo los CSV en
-- data/diagnostics/magnitude_validation/. Se ejecuta con:
--   psql ... -v csn_csv='<ruta csv csn>' -v usgs_csv='<ruta csv usgs>'
--            -f db/validate_ml_conversion.sql
--
-- Crea el esquema "validation" (tablas de trabajo, no forman parte del
-- modelo) y deja los pares emparejados para revisarlos en QGIS o SQL.
-- No modifica ninguna tabla del esquema seismic.
--
-- Formula probada: Mw = 0.9575 * Ml + 0.2412 (seismic.magnitude_conversion,
-- metodo csn_relation_ml_provisional).

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DROP SCHEMA IF EXISTS validation CASCADE;
CREATE SCHEMA validation;

-- 1. Datos descargados -------------------------------------------------------

CREATE TABLE validation.csn_daily_before (
    report_id text PRIMARY KEY,
    occurred_at timestamptz NOT NULL,
    longitude double precision NOT NULL,
    latitude double precision NOT NULL,
    depth_km numeric,
    magnitude numeric NOT NULL,
    magnitude_type text
);
-- \copy no reemplaza variables de psql; se arma el comando en una variable.
\set copy_csn '\\copy validation.csn_daily_before FROM ' :'csn_csv' ' WITH (FORMAT csv, HEADER true)'
:copy_csn

CREATE TABLE validation.usgs (
    time timestamptz, latitude double precision, longitude double precision,
    depth numeric, mag numeric, mag_type text, nst integer, gap numeric,
    dmin numeric, rms numeric, net text, id text PRIMARY KEY, updated timestamptz,
    place text, type text, horizontal_error numeric, depth_error numeric,
    mag_error numeric, mag_nst integer, status text, location_source text,
    mag_source text
);
\set copy_usgs '\\copy validation.usgs FROM ' :'usgs_csv' ' WITH (FORMAT csv, HEADER true)'
:copy_usgs

-- 2. Emparejamiento ----------------------------------------------------------
-- Mismo sismo = diferencia de hora <= 60 s y epicentros a <= 100 km.
-- Si hay varios candidatos se elige el mas cercano en tiempo.

-- 2a. Pagina diaria CSN (Ml) <-> catalogo historico CSN (MWconv), 2024-2025.
CREATE TABLE validation.pair_historical AS
SELECT DISTINCT ON (daily.report_id)
    daily.report_id,
    daily.occurred_at,
    daily.magnitude AS daily_magnitude,
    daily.magnitude_type AS daily_type,
    hist.earthquake_event_id,
    hist.magnitude AS mwconv,
    hist.reported_magnitude,
    hist.reported_magnitude_type,
    hist.magnitude_agency,
    abs(extract(epoch FROM hist.occurred_at - daily.occurred_at)) AS dt_s,
    ST_Distance(
        hist.geom::geography,
        ST_SetSRID(ST_MakePoint(daily.longitude, daily.latitude), 4326)::geography
    )::numeric / 1000 AS distance_km
FROM validation.csn_daily_before AS daily
JOIN seismic.earthquake_event AS hist
  ON hist.source_code = 'csn'
 AND hist.magnitude_type = 'MWconv'
 AND hist.occurred_at BETWEEN daily.occurred_at - interval '60 seconds'
                          AND daily.occurred_at + interval '60 seconds'
 AND ST_DWithin(
        hist.geom::geography,
        ST_SetSRID(ST_MakePoint(daily.longitude, daily.latitude), 4326)::geography,
        100000)
ORDER BY daily.report_id, dt_s;

-- 2b. CSN diario de la base (Ml, Mlv, Mw) <-> USGS, 2025-2026.
CREATE TABLE validation.pair_usgs AS
SELECT DISTINCT ON (csn.earthquake_event_id)
    csn.earthquake_event_id,
    csn.occurred_at,
    csn.magnitude AS csn_magnitude,
    csn.magnitude_type AS csn_type,
    usgs.id AS usgs_id,
    usgs.mag AS usgs_magnitude,
    lower(usgs.mag_type) AS usgs_type,
    usgs.mag_source,
    abs(extract(epoch FROM usgs.time - csn.occurred_at)) AS dt_s,
    ST_Distance(
        csn.geom::geography,
        ST_SetSRID(ST_MakePoint(usgs.longitude, usgs.latitude), 4326)::geography
    )::numeric / 1000 AS distance_km
FROM seismic.earthquake_event AS csn
JOIN validation.usgs AS usgs
  ON usgs.time BETWEEN csn.occurred_at - interval '60 seconds'
                   AND csn.occurred_at + interval '60 seconds'
 AND ST_DWithin(
        csn.geom::geography,
        ST_SetSRID(ST_MakePoint(usgs.longitude, usgs.latitude), 4326)::geography,
        100000)
WHERE csn.source_code = 'csn'
  AND csn.occurred_at >= '2025-06-24'
ORDER BY csn.earthquake_event_id, dt_s;

-- 3. Resultados ---------------------------------------------------------------

\echo '== A. Cuantos eventos se emparejaron =='
SELECT 'CSN diario 2024-2025 (Ml >= 4)' AS conjunto,
       count(*) AS eventos,
       count(pair.report_id) AS emparejados
FROM validation.csn_daily_before AS daily
LEFT JOIN validation.pair_historical AS pair USING (report_id)
WHERE daily.magnitude >= 4
UNION ALL
SELECT 'CSN diario 2025-2026 con USGS (CSN >= 4)',
       count(*), count(pair.earthquake_event_id)
FROM seismic.earthquake_event AS csn
LEFT JOIN validation.pair_usgs AS pair USING (earthquake_event_id)
WHERE csn.source_code = 'csn' AND csn.occurred_at >= '2025-06-24'
  AND csn.magnitude >= 4;

\echo '== B. Tipos de magnitud en las paginas diarias 2024-2025 =='
SELECT magnitude_type, count(*), min(magnitude), max(magnitude)
FROM validation.csn_daily_before GROUP BY 1 ORDER BY 2 DESC;

\echo '== C. Pares diario-historico: de que magnitud original salio el MWconv =='
SELECT reported_magnitude_type, magnitude_agency, count(*),
       round(avg(dt_s), 1) AS dt_s_medio, round(avg(distance_km), 1) AS km_medio
FROM validation.pair_historical
WHERE daily_magnitude >= 4
GROUP BY 1, 2 ORDER BY 3 DESC;

\echo '== D. El Ml de la pagina diaria es el mismo ML que uso el CSN? (pares con ML GUC) =='
SELECT count(*) AS pares,
       count(*) FILTER (WHERE daily_magnitude = reported_magnitude) AS identicos,
       round(avg(daily_magnitude - reported_magnitude), 3) AS diferencia_media
FROM validation.pair_historical
WHERE reported_magnitude_type = 'ML' AND magnitude_agency = 'GUC';

\echo '== E. Prueba de la formula: residuo = Mw de referencia - formula(Ml) =='
-- Referencia 1: MWconv historico. Referencia 2: Mw de USGS (mww/mwr/mwc/mwb).
WITH residuals AS (
    SELECT 'historico CSN (' || reported_magnitude_type || ' ' || magnitude_agency || ')' AS referencia,
           daily_type AS tipo_csn, daily_magnitude AS ml,
           mwconv - (0.9575 * daily_magnitude + 0.2412) AS residuo
    FROM validation.pair_historical
    WHERE lower(daily_type) IN ('ml', 'mlv', 'mlh')
    UNION ALL
    SELECT 'USGS ' || usgs_type, csn_type, csn_magnitude,
           usgs_magnitude - (0.9575 * csn_magnitude + 0.2412)
    FROM validation.pair_usgs
    WHERE lower(csn_type) IN ('ml', 'mlv', 'mlh')
      AND usgs_type IN ('mww', 'mwr', 'mwc', 'mwb', 'mw')
)
SELECT referencia, tipo_csn, count(*) AS pares,
       round(avg(residuo), 3) AS residuo_medio,
       round(stddev(residuo), 3) AS desviacion,
       round(min(ml), 1) AS ml_min, round(max(ml), 1) AS ml_max
FROM residuals
WHERE ml >= 4.0
GROUP BY 1, 2
HAVING count(*) >= 5
ORDER BY 1, 2;

\echo '== F. Residuo por tramo de Ml contra el MWconv historico (todos los pares) =='
SELECT floor(daily_magnitude * 2) / 2 AS tramo_ml,
       count(*) AS pares,
       round(avg(mwconv - (0.9575 * daily_magnitude + 0.2412)), 3) AS residuo_medio,
       round(stddev(mwconv - (0.9575 * daily_magnitude + 0.2412)), 3) AS desviacion
FROM validation.pair_historical
WHERE lower(daily_type) = 'ml'
GROUP BY 1 ORDER BY 1;

\echo '== G. Regresion libre MWconv ~ Ml diario (Ml >= 4.3, sin sesgo de umbral) =='
SELECT count(*) AS pares,
       round(regr_slope(mwconv, daily_magnitude)::numeric, 4) AS a,
       round(regr_intercept(mwconv, daily_magnitude)::numeric, 4) AS b,
       round(regr_r2(mwconv, daily_magnitude)::numeric, 3) AS r2
FROM validation.pair_historical
WHERE lower(daily_type) = 'ml' AND daily_magnitude >= 4.3;

\echo '== H. Mismo evento: Ml/Mlv del CSN contra mb de USGS convertido (formula NEIC) =='
-- Es la comparacion que imita al catalogo historico, que en 2024-2025 se
-- armaba sobre todo con mb de NEIC.
SELECT csn_type,
       count(*) AS pares,
       round(avg((1.1504 * usgs_magnitude - 0.7327) - (0.9575 * csn_magnitude + 0.2412)), 3) AS residuo_medio,
       round(stddev((1.1504 * usgs_magnitude - 0.7327) - (0.9575 * csn_magnitude + 0.2412)), 3) AS desviacion
FROM validation.pair_usgs
WHERE usgs_type = 'mb' AND lower(csn_type) IN ('ml', 'mlv')
  AND csn_magnitude >= 4.0 AND usgs_magnitude BETWEEN 4.1 AND 6.1
GROUP BY 1 ORDER BY 1;

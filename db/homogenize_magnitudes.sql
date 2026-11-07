-- Calcula mw_homogenized y mw_method para todos los eventos.
-- Explicacion completa en docs/MAGNITUDES.md (secciones 6 y 9).
--
-- Para cada evento:
--   1. Busca la regla de su fuente + tipo de magnitud
--      (seismic.magnitude_conversion_rule).
--   2. Toma la formula Mw = slope * magnitud + intercept
--      (seismic.magnitude_conversion).
--   3. Si la magnitud cae dentro del rango valido de la formula, guarda el Mw
--      redondeado a 2 decimales; si no, deja NULL (no se extrapola).
--
-- La columna magnitude (valor publicado por la fuente) no se modifica.
-- Es idempotente: solo reescribe las filas cuyo resultado cambio.
-- Lo ejecuta scripts/load_catalogs_postgis.ps1 despues de cada carga.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

BEGIN;

-- 1. Un tipo de magnitud nuevo (por ejemplo, uno que traiga USGS en el
-- futuro) se registra como 'unknown' para no perder el dato. Queda sin
-- regla, y por lo tanto sin Mw, hasta que alguien lo documente.
INSERT INTO seismic.magnitude_type (
    magnitude_type_code, family, is_moment_magnitude,
    saturation_magnitude, name_es, description
)
SELECT DISTINCT
    lower(event.magnitude_type),
    'unknown',
    false,
    NULL::numeric,
    'Tipo no catalogado: ' || lower(event.magnitude_type),
    'Agregado automaticamente por db/homogenize_magnitudes.sql. Revisar y documentar.'
FROM seismic.earthquake_event AS event
WHERE event.magnitude_type IS NOT NULL
ON CONFLICT (magnitude_type_code) DO NOTHING;

-- 2. Calculo del Mw homogeneo.
WITH candidate AS (
    SELECT
        event.earthquake_event_id,
        event.magnitude,
        conversion.conversion_method,
        conversion.slope,
        conversion.intercept,
        event.magnitude IS NOT NULL
            AND conversion.conversion_method IS NOT NULL
            AND (conversion.valid_min IS NULL OR event.magnitude >= conversion.valid_min)
            AND (conversion.valid_max IS NULL OR event.magnitude <= conversion.valid_max)
            AS applies
    FROM seismic.earthquake_event AS event
    LEFT JOIN seismic.magnitude_conversion_rule AS rule
           ON rule.source_code = event.source_code
          AND rule.magnitude_type_code = lower(event.magnitude_type)
    LEFT JOIN seismic.magnitude_conversion AS conversion
           ON conversion.conversion_method = rule.conversion_method
),
result AS (
    SELECT
        earthquake_event_id,
        CASE WHEN applies
             THEN round(slope * magnitude + intercept, 2)
        END AS mw_homogenized,
        CASE WHEN applies THEN conversion_method END AS mw_method
    FROM candidate
)
UPDATE seismic.earthquake_event AS event
SET
    mw_homogenized = result.mw_homogenized,
    mw_method = result.mw_method
FROM result
WHERE result.earthquake_event_id = event.earthquake_event_id
  AND (
      event.mw_homogenized IS DISTINCT FROM result.mw_homogenized
      OR event.mw_method IS DISTINCT FROM result.mw_method
  );

COMMIT;

ANALYZE seismic.earthquake_event;

-- Resumen visible: cuantos eventos obtuvo cada metodo y cuantos quedaron sin Mw.
SELECT
    event.source_code,
    coalesce(event.mw_method, '(sin Mw)') AS mw_method,
    coalesce(conversion.is_provisional, false) AS provisional,
    count(*) AS events,
    min(event.mw_homogenized) AS min_mw,
    max(event.mw_homogenized) AS max_mw
FROM seismic.earthquake_event AS event
LEFT JOIN seismic.magnitude_conversion AS conversion
       ON conversion.conversion_method = event.mw_method
GROUP BY 1, 2, 3
ORDER BY 1, 4 DESC;

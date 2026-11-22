-- Llena seismic.magnitude_estimate con todas las magnitudes publicadas de cada
-- evento ya cargado:
--   * la preferida (earthquake_event.magnitude / magnitude_type), y
--   * la original (reported_magnitude / reported_magnitude_type), si es distinta.
-- En el catalogo historico del CSN la preferida es MWconv (convertida por el
-- CSN) y la original es la magnitud medida por la agencia (mb, ML, Md, Mw...).
--
-- Se reconstruye completa en cada ejecucion, en una transaccion. Es idempotente.
-- Uso:
--   psql -h 127.0.0.1 -p 5433 -U sismos_app -d sismos_chile -v ON_ERROR_STOP=1 \
--        -f db/load_magnitude_estimates.sql

\set ON_ERROR_STOP on

BEGIN;

-- Los tipos de magnitud originales que no esten en el catalogo se registran
-- como 'unknown', igual que en db/homogenize_magnitudes.sql.
INSERT INTO seismic.magnitude_type (
    magnitude_type_code, family, is_moment_magnitude,
    saturation_magnitude, name_es, description
)
SELECT DISTINCT
    lower(code),
    'unknown',
    false,
    NULL::numeric,
    'Tipo no catalogado: ' || lower(code),
    'Agregado automaticamente por db/load_magnitude_estimates.sql. Revisar y documentar.'
FROM (
    SELECT magnitude_type AS code FROM seismic.earthquake_event
    UNION
    SELECT reported_magnitude_type FROM seismic.earthquake_event
) AS types
WHERE code IS NOT NULL
ON CONFLICT (magnitude_type_code) DO NOTHING;

TRUNCATE seismic.magnitude_estimate;

WITH candidate AS (
    -- Magnitud preferida.
    SELECT
        event.earthquake_event_id,
        lower(event.magnitude_type) AS magnitude_type_code,
        CASE
            WHEN lower(event.magnitude_type) = 'mwconv' THEN 'CSN'
            ELSE coalesce(event.magnitude_agency, event.magnitude_source, upper(event.source_code))
        END AS agency,
        event.magnitude AS magnitude_value,
        CASE WHEN lower(event.magnitude_type) = 'mwconv' THEN 'converted' ELSE 'reported' END AS origin,
        true AS is_preferred
    FROM seismic.earthquake_event AS event
    WHERE event.magnitude IS NOT NULL
      AND event.magnitude_type IS NOT NULL

    UNION ALL

    -- Magnitud original, cuando existe.
    SELECT
        event.earthquake_event_id,
        lower(event.reported_magnitude_type),
        coalesce(event.magnitude_agency, event.magnitude_source, upper(event.source_code)),
        event.reported_magnitude,
        'reported',
        false
    FROM seismic.earthquake_event AS event
    WHERE event.reported_magnitude IS NOT NULL
      AND event.reported_magnitude_type IS NOT NULL
)
INSERT INTO seismic.magnitude_estimate (
    earthquake_event_id, magnitude_type_code, agency,
    magnitude_value, origin, is_preferred
)
-- Si la original y la preferida son la misma (mismo tipo y agencia), queda
-- una sola fila, marcada como preferida.
SELECT DISTINCT ON (earthquake_event_id, magnitude_type_code, agency)
    earthquake_event_id, magnitude_type_code, agency,
    magnitude_value, origin, is_preferred
FROM candidate
ORDER BY earthquake_event_id, magnitude_type_code, agency, is_preferred DESC;

DO $$
DECLARE
    missing integer;
BEGIN
    SELECT count(*) INTO missing
    FROM seismic.earthquake_event AS event
    WHERE event.magnitude IS NOT NULL
      AND event.magnitude_type IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM seismic.magnitude_estimate AS estimate
          WHERE estimate.earthquake_event_id = event.earthquake_event_id
            AND estimate.is_preferred
      );
    IF missing > 0 THEN
        RAISE EXCEPTION '% eventos con magnitud quedaron sin magnitud preferida', missing;
    END IF;
END $$;

COMMIT;

ANALYZE seismic.magnitude_estimate;

SELECT
    count(*) AS magnitude_estimates,
    count(DISTINCT earthquake_event_id) AS events,
    count(*) FILTER (WHERE origin = 'converted') AS converted,
    count(*) FILTER (WHERE NOT is_preferred) AS non_preferred
FROM seismic.magnitude_estimate;

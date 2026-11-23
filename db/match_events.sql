-- Emparejamiento CSN-USGS: que registros de las dos fuentes son el mismo sismo.
-- Llena seismic.event_match (docs/PLAN_ENTREGA3.md, paso 2).
--
-- Regla:
--   1. Candidatos: un registro CSN y uno USGS a :max_dt_s segundos o menos y
--      a :max_km kilometros o menos (distancia geodesica entre epicentros).
--   2. Puntaje entre 0 y 1 que premia la cercania en tiempo y en espacio:
--          score = 1 - 0,5 * dt / max_dt - 0,5 * distancia / max_km
--      Un par con el mismo instante y el mismo epicentro tiene score 1.
--   3. Asignacion uno a uno, voraz: se recorren los candidatos de mayor a menor
--      puntaje y se acepta un par si ninguno de sus dos registros fue tomado.
--      Asi un sismo USGS queda con a lo mas un CSN y viceversa.
--
-- No borra registros: el duplicado queda vinculado. La vista
-- seismic.v_event_location_unique deja un solo registro por sismo (el del CSN,
-- fuente principal del proyecto).
--
-- Se recalcula completo en cada ejecucion, dentro de una transaccion.
-- Uso: psql ... -f db/match_events.sql
--      psql ... -v max_dt_s=30 -v max_km=50 -f db/match_events.sql   (otra regla)

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\if :{?max_dt_s}
\else
\set max_dt_s 60
\endif
\if :{?max_km}
\else
\set max_km 100
\endif

BEGIN;

CREATE TEMP TABLE match_candidate ON COMMIT DROP AS
SELECT
    csn.earthquake_event_id AS csn_event_id,
    usgs.earthquake_event_id AS usgs_event_id,
    abs(extract(epoch FROM usgs.occurred_at - csn.occurred_at))::numeric AS time_difference_s,
    (ST_Distance(csn.geom::geography, usgs.geom::geography) / 1000)::numeric AS distance_km,
    csn.mw_homogenized - usgs.mw_homogenized AS magnitude_difference
FROM seismic.earthquake_event AS usgs
JOIN seismic.earthquake_event AS csn
  ON csn.source_code = 'csn'
 AND csn.occurred_at BETWEEN usgs.occurred_at - make_interval(secs => :max_dt_s)
                         AND usgs.occurred_at + make_interval(secs => :max_dt_s)
 AND ST_DWithin(csn.geom::geography, usgs.geom::geography, :max_km * 1000)
WHERE usgs.source_code = 'usgs';

ALTER TABLE match_candidate ADD COLUMN match_score numeric;
UPDATE match_candidate
SET match_score = greatest(0, 1 - 0.5 * time_difference_s / :max_dt_s - 0.5 * distance_km / :max_km);

-- Asignacion voraz uno a uno. Las dos llaves unicas hacen el trabajo:
-- ON CONFLICT DO NOTHING descarta el par si su CSN o su USGS ya fue tomado.
CREATE TEMP TABLE match_accepted (
    csn_event_id bigint PRIMARY KEY,
    usgs_event_id bigint NOT NULL UNIQUE,
    time_difference_s numeric NOT NULL,
    distance_km numeric NOT NULL,
    magnitude_difference numeric,
    match_score numeric NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
    pair record;
BEGIN
    FOR pair IN
        SELECT *
        FROM match_candidate
        ORDER BY match_score DESC, time_difference_s, distance_km, csn_event_id, usgs_event_id
    LOOP
        INSERT INTO match_accepted VALUES (
            pair.csn_event_id, pair.usgs_event_id, pair.time_difference_s,
            pair.distance_km, pair.magnitude_difference, pair.match_score
        )
        ON CONFLICT DO NOTHING;
    END LOOP;
END
$$;

TRUNCATE seismic.event_match;

INSERT INTO seismic.event_match (
    csn_event_id, usgs_event_id, time_difference_s, distance_km,
    magnitude_difference, match_score, method
)
SELECT
    csn_event_id,
    usgs_event_id,
    round(time_difference_s, 2),
    round(distance_km, 2),
    round(magnitude_difference, 2),
    round(match_score, 4),
    format('greedy_%ss_%skm', :max_dt_s, :max_km)
FROM match_accepted;

COMMIT;

ANALYZE seismic.event_match;

-- Resumen visible.
SELECT
    method,
    count(*) AS pairs,
    round(avg(time_difference_s), 1) AS avg_dt_s,
    round(avg(distance_km), 1) AS avg_km,
    count(*) FILTER (WHERE time_difference_s > 10) AS pairs_dt_over_10s,
    round(avg(magnitude_difference), 3) AS avg_mw_difference,
    round(stddev(magnitude_difference), 3) AS sd_mw_difference
FROM seismic.event_match
GROUP BY method;

SELECT
    source_code,
    count(*) AS events,
    count(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM seismic.event_match AS pair
        WHERE pair.csn_event_id = event.earthquake_event_id
           OR pair.usgs_event_id = event.earthquake_event_id
    )) AS matched
FROM seismic.earthquake_event AS event
GROUP BY source_code
ORDER BY source_code;

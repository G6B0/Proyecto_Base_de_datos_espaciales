-- ST-DBSCAN: agrupamiento por densidad en espacio y tiempo (Birant y Kut,
-- 2007; diapositiva 97 de la materia). Alternativa a Gardner-Knopoff para
-- comparar (docs/PLAN_ENTREGA3.md, paso 3).
--
-- ST_ClusterDBSCAN de PostGIS solo mira el espacio, asi que el metodo se
-- escribe en SQL:
--   1. Vecinos: pares de sismos a :eps_km km o menos (distancia geodesica)
--      Y a :eps_days dias o menos.
--   2. Nucleos: sismos con al menos :min_pts sismos en su vecindad
--      (contandose a si mismos, como en DBSCAN).
--   3. Grupos: componentes conectadas de los nucleos vecinos entre si
--      (propagacion de la etiqueta minima hasta que no cambie).
--   4. Borde: un sismo que no es nucleo pero es vecino de uno se une al grupo
--      de su nucleo mas cercano en el tiempo. El resto es ruido.
-- Cada grupo es una secuencia: su sismo de mayor Mw es el principal, los
-- anteriores son precursores y los posteriores replicas. El ruido queda como
-- independiente. A diferencia de Gardner-Knopoff, las ventanas no dependen de
-- la magnitud: el grupo crece encadenando sismos cercanos.
--
-- Parametros (psql -v): catalog (unique|usgs|csn, por defecto unique),
-- min_mw (4.0), period_start (1960-01-01), eps_km (40), eps_days (10),
-- min_pts (5). Repetir con los mismos parametros reemplaza la ejecucion.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\if :{?catalog}
\else
\set catalog unique
\endif
\if :{?min_mw}
\else
\set min_mw 4.0
\endif
\if :{?period_start}
\else
\set period_start 1960-01-01
\endif
\if :{?eps_km}
\else
\set eps_km 40
\endif
\if :{?eps_days}
\else
\set eps_days 10
\endif
\if :{?min_pts}
\else
\set min_pts 5
\endif

BEGIN;

CREATE TEMP TABLE sd_params ON COMMIT DROP AS
SELECT
    :'catalog'::text AS catalog,
    CASE WHEN :'catalog' = 'unique' THEN NULL ELSE :'catalog' END AS source_code,
    :min_mw::numeric AS min_mw,
    :'period_start'::timestamptz AS period_start,
    :eps_km::numeric AS eps_km,
    :eps_days::numeric AS eps_days,
    :min_pts::int AS min_pts,
    jsonb_build_object('eps_km', :eps_km::numeric, 'eps_dias', :eps_days::numeric,
                       'min_pts', :min_pts::int,
                       'referencia', 'Birant y Kut (2007), ST-DBSCAN') AS parameters;

DELETE FROM seismic.declustering_run AS run
USING sd_params AS p
WHERE run.method = 'st_dbscan'
  AND run.catalog = CASE WHEN p.catalog = 'unique' THEN 'unique' ELSE 'source' END
  AND run.source_code IS NOT DISTINCT FROM p.source_code
  AND run.minimum_magnitude = p.min_mw
  AND run.period_start = p.period_start
  AND run.parameters = p.parameters;

CREATE TEMP TABLE sd_run ON COMMIT DROP AS
WITH inserted AS (
    INSERT INTO seismic.declustering_run (
        method, parameters, catalog, source_code, minimum_magnitude, period_start
    )
    SELECT 'st_dbscan', p.parameters, CASE WHEN p.catalog = 'unique' THEN 'unique' ELSE 'source' END,
           p.source_code, p.min_mw, p.period_start
    FROM sd_params AS p
    RETURNING declustering_run_id
)
SELECT * FROM inserted;

-- Catalogo de trabajo.
CREATE TEMP TABLE sd_cat ON COMMIT DROP AS
SELECT e.earthquake_event_id AS id, e.occurred_at AS t, e.geom::geography AS geog, e.geom,
       e.mw_homogenized AS mw
FROM seismic.v_event_location_unique AS e, sd_params AS p
WHERE p.catalog = 'unique' AND e.mw_homogenized >= p.min_mw AND e.occurred_at >= p.period_start
UNION ALL
SELECT e.earthquake_event_id, e.occurred_at, e.geom::geography, e.geom, e.mw_homogenized
FROM seismic.earthquake_event AS e, sd_params AS p
WHERE p.catalog <> 'unique' AND e.source_code = p.catalog
  AND e.mw_homogenized >= p.min_mw AND e.occurred_at >= p.period_start;
CREATE INDEX ON sd_cat USING gist (geog);
CREATE INDEX ON sd_cat (t);
ANALYZE sd_cat;

-- 1. Pares vecinos en espacio y tiempo (sin el propio sismo).
CREATE TEMP TABLE sd_pair ON COMMIT DROP AS
SELECT a.id AS a, b.id AS b, abs(extract(epoch FROM b.t - a.t)) AS dt_s
FROM sd_cat AS a
JOIN sd_cat AS b
  ON b.t BETWEEN a.t - make_interval(days => (SELECT eps_days FROM sd_params)::int)
             AND a.t + make_interval(days => (SELECT eps_days FROM sd_params)::int)
 AND b.id <> a.id
 AND ST_DWithin(a.geog, b.geog, (SELECT eps_km FROM sd_params) * 1000);
CREATE INDEX ON sd_pair (a);
ANALYZE sd_pair;

-- 2. Nucleos.
CREATE TEMP TABLE sd_point ON COMMIT DROP AS
SELECT c.id, c.t, c.mw,
       (count(p.b) + 1) >= (SELECT min_pts FROM sd_params) AS is_core,
       NULL::bigint AS label
FROM sd_cat AS c
LEFT JOIN sd_pair AS p ON p.a = c.id
GROUP BY c.id, c.t, c.mw;
UPDATE sd_point SET label = id WHERE is_core;
CREATE INDEX ON sd_point (id);
ANALYZE sd_point;

-- 3. Componentes conectadas entre nucleos: cada nucleo toma la etiqueta
-- minima de sus nucleos vecinos hasta que nada cambie.
DO $$
DECLARE
    changed integer;
    rounds integer := 0;
BEGIN
    LOOP
        UPDATE sd_point AS target
        SET label = best.label
        FROM (
            SELECT pair.a AS id, min(neighbour.label) AS label
            FROM sd_pair AS pair
            JOIN sd_point AS neighbour ON neighbour.id = pair.b AND neighbour.is_core
            GROUP BY pair.a
        ) AS best
        WHERE target.id = best.id AND target.is_core AND best.label < target.label;
        GET DIAGNOSTICS changed = ROW_COUNT;
        rounds := rounds + 1;
        EXIT WHEN changed = 0 OR rounds > 500;
    END LOOP;
    RAISE NOTICE 'ST-DBSCAN: % rondas de propagacion', rounds;
END
$$;

-- 4. Borde: el nucleo vecino mas cercano en el tiempo.
UPDATE sd_point AS target
SET label = border.label
FROM (
    SELECT DISTINCT ON (pair.a) pair.a AS id, core.label
    FROM sd_pair AS pair
    JOIN sd_point AS core ON core.id = pair.b AND core.is_core
    ORDER BY pair.a, pair.dt_s
) AS border
WHERE target.id = border.id AND NOT target.is_core;

-- Principal de cada grupo: el de mayor Mw (el mas antiguo si empatan).
CREATE TEMP TABLE sd_main ON COMMIT DROP AS
SELECT DISTINCT ON (label) label, id AS mainshock_id, t AS main_t
FROM sd_point
WHERE label IS NOT NULL
ORDER BY label, mw DESC, t;

INSERT INTO seismic.seismic_sequence (
    declustering_run_id, mainshock_event_id, foreshock_count, aftershock_count,
    largest_aftershock_magnitude, started_at, ended_at, footprint
)
SELECT
    run.declustering_run_id, m.mainshock_id,
    count(*) FILTER (WHERE p.t < m.main_t),
    count(*) FILTER (WHERE p.t > m.main_t OR (p.t = m.main_t AND p.id <> m.mainshock_id)),
    max(p.mw) FILTER (WHERE p.id <> m.mainshock_id AND p.t >= m.main_t),
    min(p.t), max(p.t),
    CASE WHEN ST_GeometryType(ST_ConvexHull(ST_Collect(c.geom))) = 'ST_Polygon'
         THEN ST_ConvexHull(ST_Collect(c.geom)) END
FROM sd_point AS p
JOIN sd_main AS m USING (label)
JOIN sd_cat AS c ON c.id = p.id
CROSS JOIN sd_run AS run
GROUP BY run.declustering_run_id, m.mainshock_id;

INSERT INTO seismic.event_sequence_role (
    declustering_run_id, earthquake_event_id, seismic_sequence_id, role,
    time_from_mainshock, distance_to_mainshock_km
)
SELECT
    run.declustering_run_id, p.id, s.seismic_sequence_id,
    CASE WHEN p.label IS NULL THEN 'independent'
         WHEN p.id = m.mainshock_id THEN 'mainshock'
         WHEN p.t < m.main_t THEN 'foreshock'
         ELSE 'aftershock' END,
    CASE WHEN p.label IS NOT NULL THEN p.t - m.main_t END,
    CASE WHEN p.label IS NOT NULL
         THEN round((ST_Distance(c.geog, mc.geog) / 1000)::numeric, 2) END
FROM sd_point AS p
JOIN sd_cat AS c ON c.id = p.id
CROSS JOIN sd_run AS run
LEFT JOIN sd_main AS m ON m.label = p.label
LEFT JOIN sd_cat AS mc ON mc.id = m.mainshock_id
LEFT JOIN seismic.seismic_sequence AS s
       ON s.declustering_run_id = run.declustering_run_id AND s.mainshock_event_id = m.mainshock_id;

UPDATE seismic.declustering_run AS run
SET period_end = (SELECT max(t) FROM sd_cat)
FROM sd_run
WHERE run.declustering_run_id = sd_run.declustering_run_id;

COMMIT;

ANALYZE seismic.seismic_sequence;
ANALYZE seismic.event_sequence_role;

SELECT run.declustering_run_id AS run, coalesce(run.source_code, 'csn+usgs') AS fuente,
       role.role, count(*) AS sismos
FROM seismic.event_sequence_role AS role
JOIN seismic.declustering_run AS run USING (declustering_run_id)
WHERE run.declustering_run_id = (SELECT max(declustering_run_id) FROM seismic.declustering_run
                                 WHERE method = 'st_dbscan')
GROUP BY 1, 2, 3
ORDER BY sismos DESC;

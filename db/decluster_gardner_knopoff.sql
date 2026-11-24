-- Declustering de Gardner y Knopoff (1974): separa sismos principales,
-- precursores, replicas e independientes. Llena declustering_run,
-- seismic_sequence y event_sequence_role (docs/PLAN_ENTREGA3.md, paso 3).
--
-- Ventanas (van Stiphout et al., 2012), con M = Mw homogeneo del principal:
--   distancia L(M) = 10^(0,1238 M + 0,983) km
--   tiempo    T(M) = 10^(0,5409 M - 0,547) dias  si M < 6,5
--             T(M) = 10^(0,032 M + 2,7389) dias  si M >= 6,5
-- Algoritmo: se recorren los sismos de mayor a menor Mw. El primero sin
-- clasificar es principal; los sismos sin clasificar a L(M) km o menos y
-- hasta T(M) dias despues son sus replicas, y los de hasta
-- :foreshock_days dias antes, sus precursores. Si nadie cae en su ventana,
-- es independiente.
--
-- Ventana de precursores: el borrador del 12-11 usaba T(M) tambien hacia
-- atras (hasta ~3 anos) y marcaba como precursores 12.827 sismos. Los
-- precursores ocurren dias o semanas antes, asi que por defecto se usan
-- 30 dias (min(T(M), 30)). Con -v foreshock_days=-1 se usa T(M) completo.
--
-- Parametros (psql -v):
--   catalog        'unique' (por defecto: v_event_location_unique, sin
--                  duplicados CSN-USGS) o 'usgs' (solo USGS, decision D9)
--   min_mw         Mw minimo (por defecto 4.0)
--   period_start   fecha de inicio (por defecto 1960-01-01: antes los
--                  epicentros tienen errores de decenas de km)
--   foreshock_days ventana de precursores en dias (por defecto 30)
--
-- Uso: psql ... -f db/decluster_gardner_knopoff.sql
--      psql ... -v catalog=usgs -f db/decluster_gardner_knopoff.sql
-- Repetir con los mismos parametros reemplaza la ejecucion anterior.

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
\if :{?foreshock_days}
\else
\set foreshock_days 30
\endif

BEGIN;

CREATE TEMP TABLE gk_params ON COMMIT DROP AS
SELECT
    :'catalog'::text AS catalog,
    CASE WHEN :'catalog' = 'unique' THEN NULL ELSE :'catalog' END AS source_code,
    :min_mw::numeric AS min_mw,
    :'period_start'::timestamptz AS period_start,
    :foreshock_days::numeric AS foreshock_days,
    jsonb_build_object(
        'distancia_km', jsonb_build_object('a', 0.1238, 'b', 0.983),
        'tiempo_dias_m_menor_6_5', jsonb_build_object('a', 0.5409, 'b', -0.547),
        'tiempo_dias_m_mayor_6_5', jsonb_build_object('a', 0.032, 'b', 2.7389),
        'ventana_precursores_dias', :foreshock_days::numeric,
        'referencia', 'Gardner y Knopoff (1974); coeficientes de van Stiphout et al. (2012)'
    ) AS parameters;

DO $$
BEGIN
    IF (SELECT catalog FROM gk_params) NOT IN ('unique', 'usgs', 'csn') THEN
        RAISE EXCEPTION 'catalog debe ser unique, usgs o csn';
    END IF;
END
$$;

-- 1. La ejecucion: se borra la anterior con los mismos parametros (sus
-- secuencias y roles caen en cascada) y se registra la nueva.
DELETE FROM seismic.declustering_run AS run
USING gk_params AS p
WHERE run.method = 'gardner_knopoff_1974'
  AND run.catalog = CASE WHEN p.catalog = 'unique' THEN 'unique' ELSE 'source' END
  AND run.source_code IS NOT DISTINCT FROM p.source_code
  AND run.minimum_magnitude = p.min_mw
  AND run.period_start = p.period_start
  AND run.parameters = p.parameters;

CREATE TEMP TABLE gk_run ON COMMIT DROP AS
WITH inserted AS (
    INSERT INTO seismic.declustering_run (
        method, parameters, catalog, source_code, minimum_magnitude, period_start, period_end
    )
    SELECT 'gardner_knopoff_1974', p.parameters,
           CASE WHEN p.catalog = 'unique' THEN 'unique' ELSE 'source' END,
           p.source_code, p.min_mw, p.period_start, NULL
    FROM gk_params AS p
    RETURNING declustering_run_id, parameters
)
SELECT * FROM inserted;

-- 2. Catalogo de trabajo.
CREATE TEMP TABLE gk_cat ON COMMIT DROP AS
SELECT e.earthquake_event_id AS id, e.occurred_at AS t, e.geom::geography AS geog, e.geom,
       e.mw_homogenized AS mw, NULL::text AS role, NULL::bigint AS mainshock_id
FROM seismic.v_event_location_unique AS e, gk_params AS p
WHERE p.catalog = 'unique' AND e.mw_homogenized >= p.min_mw AND e.occurred_at >= p.period_start
UNION ALL
SELECT e.earthquake_event_id, e.occurred_at, e.geom::geography, e.geom,
       e.mw_homogenized, NULL, NULL
FROM seismic.earthquake_event AS e, gk_params AS p
WHERE p.catalog <> 'unique' AND e.source_code = p.catalog
  AND e.mw_homogenized >= p.min_mw AND e.occurred_at >= p.period_start;

CREATE INDEX ON gk_cat USING gist (geog);
CREATE INDEX ON gk_cat (t);
CREATE INDEX ON gk_cat (id);
ANALYZE gk_cat;

-- 3. Algoritmo.
DO $$
DECLARE
    fs_days numeric := (SELECT foreshock_days FROM gk_params);
    candidate record;
    km double precision;
    days double precision;
    back_days double precision;
    members integer;
BEGIN
    FOR candidate IN SELECT id, t, geog, mw FROM gk_cat ORDER BY mw DESC, t LOOP
        CONTINUE WHEN (SELECT role FROM gk_cat WHERE id = candidate.id) IS NOT NULL;

        km := 10 ^ (0.1238 * candidate.mw + 0.983);
        days := CASE WHEN candidate.mw >= 6.5 THEN 10 ^ (0.032 * candidate.mw + 2.7389)
                     ELSE 10 ^ (0.5409 * candidate.mw - 0.547) END;
        back_days := CASE WHEN fs_days < 0 THEN days ELSE least(days, fs_days) END;

        UPDATE gk_cat AS c
        SET role = CASE WHEN c.t < candidate.t THEN 'foreshock' ELSE 'aftershock' END,
            mainshock_id = candidate.id
        WHERE c.role IS NULL
          AND c.id <> candidate.id
          AND c.t BETWEEN candidate.t - make_interval(secs => back_days * 86400)
                      AND candidate.t + make_interval(secs => days * 86400)
          AND ST_DWithin(c.geog, candidate.geog, km * 1000);
        GET DIAGNOSTICS members = ROW_COUNT;

        UPDATE gk_cat
        SET role = CASE WHEN members > 0 THEN 'mainshock' ELSE 'independent' END,
            mainshock_id = CASE WHEN members > 0 THEN candidate.id END
        WHERE id = candidate.id;
    END LOOP;
END
$$;

-- 4. Secuencias (una fila por principal) y roles (una fila por sismo).
INSERT INTO seismic.seismic_sequence (
    declustering_run_id, mainshock_event_id, foreshock_count, aftershock_count,
    largest_aftershock_magnitude, started_at, ended_at, footprint
)
SELECT
    run.declustering_run_id,
    c.mainshock_id,
    count(*) FILTER (WHERE c.role = 'foreshock'),
    count(*) FILTER (WHERE c.role = 'aftershock'),
    max(c.mw) FILTER (WHERE c.role = 'aftershock'),
    min(c.t),
    max(c.t),
    CASE WHEN ST_GeometryType(ST_ConvexHull(ST_Collect(c.geom))) = 'ST_Polygon'
         THEN ST_ConvexHull(ST_Collect(c.geom)) END
FROM gk_cat AS c, gk_run AS run
WHERE c.mainshock_id IS NOT NULL
GROUP BY run.declustering_run_id, c.mainshock_id;

INSERT INTO seismic.event_sequence_role (
    declustering_run_id, earthquake_event_id, seismic_sequence_id, role,
    time_from_mainshock, distance_to_mainshock_km
)
SELECT
    run.declustering_run_id,
    c.id,
    s.seismic_sequence_id,
    c.role,
    CASE WHEN c.role <> 'independent' THEN c.t - m.t END,
    CASE WHEN c.role <> 'independent'
         THEN round((ST_Distance(c.geog, m.geog) / 1000)::numeric, 2) END
FROM gk_cat AS c
CROSS JOIN gk_run AS run
LEFT JOIN gk_cat AS m ON m.id = c.mainshock_id
LEFT JOIN seismic.seismic_sequence AS s
       ON s.declustering_run_id = run.declustering_run_id
      AND s.mainshock_event_id = c.mainshock_id;

UPDATE seismic.declustering_run AS run
SET period_end = (SELECT max(t) FROM gk_cat)
FROM gk_run
WHERE run.declustering_run_id = gk_run.declustering_run_id;

COMMIT;

ANALYZE seismic.seismic_sequence;
ANALYZE seismic.event_sequence_role;

-- Resumen visible de la ejecucion recien hecha.
SELECT run.declustering_run_id AS run, run.catalog, coalesce(run.source_code, 'csn+usgs') AS fuente,
       role.role, count(*) AS sismos
FROM seismic.event_sequence_role AS role
JOIN seismic.declustering_run AS run USING (declustering_run_id)
WHERE run.declustering_run_id = (SELECT max(declustering_run_id) FROM seismic.declustering_run
                                 WHERE method = 'gardner_knopoff_1974')
GROUP BY 1, 2, 3, 4
ORDER BY sismos DESC;

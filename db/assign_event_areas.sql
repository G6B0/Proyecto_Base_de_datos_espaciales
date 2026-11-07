-- Asigna cada sismo a una comuna de la DPA 2023.
--
-- Regla (modelo v2, ver docs/MODELO_LOGICO_v2.md):
--   1. 'covers'  : el epicentro esta dentro de una comuna (ST_Covers).
--                  distance_km = 0.
--   2. 'nearest' : el epicentro esta en el mar o fuera de Chile. Se asigna
--                  la comuna mas cercana y se guarda la distancia geodesica
--                  en km. Asi un sismo frente a Iquique queda asociado a
--                  Iquique, pero la distancia permite filtrarlo.
-- La provincia y la region se obtienen subiendo por parent_area_id
-- (vista seismic.v_event_location); no se duplican aqui.
--
-- Se recalcula completo en cada ejecucion (son segundos), dentro de una
-- transaccion: si algo falla, la asignacion anterior queda intacta.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM seismic.administrative_area_part) THEN
        RAISE EXCEPTION 'No hay comunas cargadas. Ejecuta primero scripts/load_dpa_postgis.ps1';
    END IF;
END
$$;

TRUNCATE seismic.event_administrative_area;

-- Paso 1: epicentros dentro de una comuna.
-- Un punto exactamente sobre el limite entre dos comunas queda cubierto por
-- ambas; DISTINCT ON elige una de forma determinista (menor codigo).
INSERT INTO seismic.event_administrative_area (
    earthquake_event_id, administrative_area_id, assignment_method, distance_km
)
SELECT DISTINCT ON (event.earthquake_event_id)
    event.earthquake_event_id,
    area.administrative_area_id,
    'covers',
    0
FROM seismic.earthquake_event AS event
JOIN seismic.administrative_area_part AS part
  ON ST_Covers(part.geom, event.geom)
JOIN seismic.administrative_area AS area
  ON area.administrative_area_id = part.administrative_area_id
ORDER BY event.earthquake_event_id, area.official_code;

-- Paso 2: epicentros fuera de toda comuna (mar, Argentina, Bolivia, Peru).
-- El operador <-> usa el indice GiST para traer los 10 trozos de comuna mas
-- cercanos en grados; luego ST_Distance sobre geography calcula la distancia
-- real en metros sobre el elipsoide y se elige la menor. Se hace en dos
-- pasos porque un grado de longitud mide menos km en el sur que en el norte.
INSERT INTO seismic.event_administrative_area (
    earthquake_event_id, administrative_area_id, assignment_method, distance_km
)
SELECT
    event.earthquake_event_id,
    best.administrative_area_id,
    'nearest',
    round((best.distance_m / 1000.0)::numeric, 3)
FROM seismic.earthquake_event AS event
CROSS JOIN LATERAL (
    SELECT
        candidate.administrative_area_id,
        ST_Distance(candidate.geom::geography, event.geom::geography) AS distance_m
    FROM (
        SELECT part.administrative_area_id, part.geom
        FROM seismic.administrative_area_part AS part
        ORDER BY part.geom <-> event.geom
        LIMIT 10
    ) AS candidate
    ORDER BY distance_m
    LIMIT 1
) AS best
WHERE NOT EXISTS (
    SELECT 1
    FROM seismic.event_administrative_area AS assigned
    WHERE assigned.earthquake_event_id = event.earthquake_event_id
);

COMMIT;

ANALYZE seismic.event_administrative_area;

-- Resumen visible.
SELECT
    assignment_method,
    count(*) AS events,
    round(avg(distance_km), 1) AS avg_distance_km,
    max(distance_km) AS max_distance_km
FROM seismic.event_administrative_area
GROUP BY assignment_method
ORDER BY assignment_method;

SELECT
    (SELECT count(*) FROM seismic.earthquake_event) AS events_total,
    (SELECT count(*) FROM seismic.event_administrative_area) AS events_assigned;

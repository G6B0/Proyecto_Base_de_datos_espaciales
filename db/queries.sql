-- 1. Sismos de los ultimos 30 dias, de mayor a menor magnitud.
SELECT
    source_event_id,
    occurred_at,
    magnitude,
    magnitude_type,
    depth_km,
    place,
    ST_Y(geom) AS latitude,
    ST_X(geom) AS longitude
FROM seismic.earthquake_event
WHERE occurred_at >= now() - interval '30 days'
ORDER BY magnitude DESC NULLS LAST, occurred_at DESC;

-- 2. Asignar cada epicentro terrestre a las regiones que lo contienen.
-- ST_Covers incluye puntos ubicados exactamente en el borde del poligono.
INSERT INTO seismic.event_administrative_area (
    earthquake_event_id,
    administrative_area_id
)
SELECT
    event.earthquake_event_id,
    area.administrative_area_id
FROM seismic.earthquake_event AS event
JOIN seismic.administrative_area AS area
    ON area.level = 'region'
   AND ST_Covers(area.geom, event.geom)
ON CONFLICT DO NOTHING;

-- 3. Cantidad y magnitud maxima por region durante el ultimo ano.
SELECT
    area.official_code AS region_code,
    area.name AS region_name,
    count(*) AS earthquake_count,
    round(avg(event.magnitude), 2) AS average_magnitude,
    max(event.magnitude) AS maximum_magnitude
FROM seismic.earthquake_event AS event
JOIN seismic.event_administrative_area AS relation
    USING (earthquake_event_id)
JOIN seismic.administrative_area AS area
    USING (administrative_area_id)
WHERE area.level = 'region'
  AND event.occurred_at >= now() - interval '1 year'
GROUP BY area.official_code, area.name
ORDER BY earthquake_count DESC;

-- 4. Sismos a menos de 100 km de Santiago durante el ultimo ano.
-- ST_DWithin sobre geography mide en metros sobre el elipsoide.
WITH place AS (
    SELECT ST_SetSRID(ST_MakePoint(-70.6693, -33.4489), 4326) AS geom
)
SELECT
    event.source_event_id,
    event.occurred_at,
    event.magnitude,
    event.depth_km,
    round(
        ST_Distance(event.geom::geography, place.geom::geography) / 1000
    ) AS distance_km
FROM seismic.earthquake_event AS event
CROSS JOIN place
WHERE event.occurred_at >= now() - interval '1 year'
  AND ST_DWithin(event.geom::geography, place.geom::geography, 100000)
ORDER BY event.occurred_at DESC;

-- 5. Agrupamientos espaciales aproximados de los ultimos 30 dias.
-- Web Mercator se usa aqui solo para una demostracion con distancia en metros.
WITH recent AS (
    SELECT
        earthquake_event_id,
        geom,
        ST_ClusterDBSCAN(
            ST_Transform(geom, 3857),
            eps := 50000,
            minpoints := 4
        ) OVER () AS cluster_id
    FROM seismic.earthquake_event
    WHERE occurred_at >= now() - interval '30 days'
)
SELECT
    cluster_id,
    count(*) AS earthquake_count,
    ST_Centroid(ST_Collect(geom)) AS cluster_centroid
FROM recent
WHERE cluster_id IS NOT NULL
GROUP BY cluster_id
ORDER BY earthquake_count DESC;

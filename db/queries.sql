-- Consultas basicas del modelo v2 (Entregas 2 y 3).
-- Requisitos: catalogos cargados (load_catalogs_postgis.ps1), DPA cargada
-- (load_dpa_postgis.ps1), Censo 2024 cargado para las consultas 11 a 14
-- (load_ine_manzanas_postgis.ps1) y emparejamiento CSN-USGS
-- (db/match_events.sql) para contar sin duplicados. Explicacion en
-- docs/MODELO_LOGICO_v2.md.
--
-- Sin duplicados: desde la entrega 3 la base tiene el catalogo USGS completo,
-- y muchos sismos estan una vez por fuente. Las consultas que cuentan sismos
-- usan seismic.v_event_location_unique (un registro por sismo: el del CSN si
-- existe) o excluyen los registros USGS que tienen par en event_match.
--
-- Recordatorio sobre la asignacion de comuna (seismic.event_administrative_area):
--   assignment_method = 'covers'  -> epicentro dentro de la comuna.
--   assignment_method = 'nearest' -> epicentro en el mar o en otro pais;
--                                   distance_km dice a cuantos km esta.
-- Para hablar de "sismos de una region" se recomienda usar
--   distance_km <= 100  (tierra + franja costera donde ocurre la subduccion).
-- Magnitudes (docs/MAGNITUDES.md):
--   magnitude      = valor publicado por la fuente; mezcla escalas
--                    (MWconv, Ml, Mlv, mb...). Leer junto con magnitude_type.
--   mw_homogenized = Mw estimado; es la columna para filtrar y comparar.
--                    NULL en sismos chicos sin formula confiable.

-- 1. Sismos de los ultimos 30 dias con su comuna y region.
SELECT
    occurred_at,
    source_code,
    magnitude,
    magnitude_type,
    mw_homogenized,
    mw_method,
    depth_km,
    commune_name,
    region_name,
    assignment_method,
    distance_km
FROM seismic.v_event_location
WHERE occurred_at >= now() - interval '30 days'
ORDER BY magnitude DESC NULLS LAST, occurred_at DESC;

-- 2. Cantidad de sismos Mw>=4 y Mw maximo por region (tierra + 100 km de costa).
SELECT
    region_code,
    region_name,
    count(*) AS earthquake_count,
    count(*) FILTER (WHERE assignment_method = 'covers') AS inland,
    count(*) FILTER (WHERE assignment_method = 'nearest') AS offshore_or_border,
    max(mw_homogenized) AS maximum_mw
FROM seismic.v_event_location_unique
WHERE distance_km <= 100
  AND mw_homogenized >= 4
GROUP BY region_code, region_name
ORDER BY earthquake_count DESC;

-- 3. Las 10 comunas con mas sismos Mw>=5 con epicentro DENTRO de la comuna.
SELECT
    commune_name,
    region_name,
    count(*) AS earthquakes_mw5
FROM seismic.v_event_location_unique
WHERE assignment_method = 'covers'
  AND mw_homogenized >= 5
GROUP BY commune_name, region_name
ORDER BY earthquakes_mw5 DESC
LIMIT 10;

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
  AND NOT EXISTS (SELECT 1 FROM seismic.event_match AS pair WHERE pair.usgs_event_id = event.earthquake_event_id)
ORDER BY event.occurred_at DESC;

-- 5. Sismos dentro de una region usando directamente su poligono
-- (relacion espacial calculada en la consulta, sin la tabla de asignacion).
-- Usa los trozos de comuna para aprovechar el indice GiST.
SELECT
    count(DISTINCT event.earthquake_event_id) AS earthquakes_inside_region
FROM seismic.administrative_area AS region
JOIN seismic.administrative_area AS province
  ON province.parent_area_id = region.administrative_area_id
JOIN seismic.administrative_area AS commune
  ON commune.parent_area_id = province.administrative_area_id
JOIN seismic.administrative_area_part AS part
  ON part.administrative_area_id = commune.administrative_area_id
JOIN seismic.earthquake_event AS event
  ON ST_Covers(part.geom, event.geom)
WHERE region.level = 'region'
  AND region.official_code = '05'  -- 05 = Valparaiso (codigo CUT)
  AND NOT EXISTS (SELECT 1 FROM seismic.event_match AS pair WHERE pair.usgs_event_id = event.earthquake_event_id);

-- 6. Densidad de sismos por 1.000 km2 de cada region (solo epicentros en tierra).
SELECT
    region.name AS region_name,
    region.official_area_km2,
    count(location.earthquake_event_id) AS inland_earthquakes,
    round(
        1000 * count(location.earthquake_event_id) / region.official_area_km2,
        2
    ) AS earthquakes_per_1000_km2
FROM seismic.administrative_area AS region
LEFT JOIN seismic.v_event_location_unique AS location
       ON location.region_code = region.official_code
      AND location.assignment_method = 'covers'
WHERE region.level = 'region'
GROUP BY region.name, region.official_area_km2
ORDER BY earthquakes_per_1000_km2 DESC;

-- 7. Distribucion por profundidad y region (superficial < 70 km,
-- intermedia 70-300 km, profunda > 300 km).
SELECT
    region_name,
    count(*) FILTER (WHERE depth_km < 70) AS shallow,
    count(*) FILTER (WHERE depth_km BETWEEN 70 AND 300) AS intermediate,
    count(*) FILTER (WHERE depth_km > 300) AS deep,
    count(*) FILTER (WHERE depth_km IS NULL) AS without_depth
FROM seismic.v_event_location_unique
WHERE distance_km <= 100
GROUP BY region_name
ORDER BY region_name;

-- 8. Control de calidad: tipos de magnitud por fuente, que significan y
-- como se convirtieron a Mw.
SELECT
    event.source_code,
    event.magnitude_type,
    kind.name_es,
    coalesce(event.mw_method, '(sin Mw)') AS mw_method,
    count(*) AS events,
    min(event.occurred_at)::date AS first_event,
    max(event.occurred_at)::date AS last_event
FROM seismic.earthquake_event AS event
LEFT JOIN seismic.magnitude_type AS kind
       ON kind.magnitude_type_code = lower(event.magnitude_type)
GROUP BY 1, 2, 3, 4
ORDER BY event.source_code, events DESC;

-- 9. Agrupamientos espaciales aproximados de los ultimos 30 dias.
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
    FROM seismic.earthquake_event AS event
    WHERE occurred_at >= now() - interval '30 days'
      AND NOT EXISTS (SELECT 1 FROM seismic.event_match AS pair WHERE pair.usgs_event_id = event.earthquake_event_id)
)
SELECT
    cluster_id,
    count(*) AS earthquake_count,
    ST_Centroid(ST_Collect(geom)) AS cluster_centroid
FROM recent
WHERE cluster_id IS NOT NULL
GROUP BY cluster_id
ORDER BY earthquake_count DESC;

-- 10. Efecto del cambio de producto CSN el 24-06-2025 (catalogo historico
-- MWconv -> paginas diarias Ml/Mlv/Mw). La magnitud cruda no es comparable.
-- Entre Mw 4 y 4,5 el historico trae ademas sismos regionales de boletines
-- internacionales; sobre Mw 4,5 los periodos si son comparables
-- (docs/MAGNITUDES.md, secciones 8 y 10).
SELECT
    CASE WHEN occurred_at < '2025-06-24' THEN '1. historico (MWconv)'
         ELSE '2. diario (Ml/Mlv/Mw)' END AS period,
    count(*) AS all_events,
    count(*) FILTER (WHERE magnitude >= 4) AS raw_m4,
    count(*) FILTER (WHERE mw_homogenized >= 4) AS mw4,
    count(*) FILTER (WHERE mw_homogenized >= 4.5) AS mw4_5,
    count(*) FILTER (WHERE mw_homogenized >= 5) AS mw5
FROM seismic.earthquake_event
WHERE source_code = 'csn'
  AND occurred_at >= '2024-06-24'
  AND occurred_at < '2026-06-24'
GROUP BY 1
ORDER BY 1;

\timing on
-- ---------------------------------------------------------------------------
-- Zonas urbanas y poblacion (Censo 2024; docs/INE_CENSO2024.md). Requieren
-- scripts/load_ine_manzanas_postgis.ps1.
--   event_urban_area.distance_rank = 1 -> zona urbana mas cercana (todo sismo).
--   epicentral_distance_km = 0         -> epicentro dentro de la zona urbana.
--   hypocentral_distance_km            -> incluye la profundidad.
-- ---------------------------------------------------------------------------

-- 11. Zona urbana mas cercana a los 10 sismos de mayor Mw.
SELECT
    event.occurred_at::date AS date,
    event.mw_homogenized AS mw,
    event.depth_km,
    urban.name AS nearest_urban_area,
    urban.category,
    commune.name AS commune_name,
    link.epicentral_distance_km,
    link.hypocentral_distance_km,
    urban.population
FROM seismic.earthquake_event AS event
JOIN seismic.event_urban_area AS link
  ON link.earthquake_event_id = event.earthquake_event_id
 AND link.distance_rank = 1
JOIN seismic.urban_area AS urban ON urban.urban_area_id = link.urban_area_id
JOIN seismic.administrative_area AS commune ON commune.administrative_area_id = urban.commune_area_id
WHERE event.mw_homogenized IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM seismic.event_match AS pair WHERE pair.usgs_event_id = event.earthquake_event_id)
ORDER BY event.mw_homogenized DESC, event.occurred_at
LIMIT 10;

-- 12. Los 10 sismos Mw>=6 desde 1960 con mas poblacion censada (Censo 2024)
-- a 50 km del epicentro. Desde 1960 porque los epicentros historicos tienen
-- errores de decenas de km. Es poblacion que HOY vive cerca, no dano.
SELECT
    event.occurred_at::date AS date,
    event.mw_homogenized AS mw,
    event.depth_km,
    location.commune_name,
    exposure.population_25km,
    exposure.population_50km,
    exposure.population_100km,
    exposure.population_60_plus_50km,
    exposure.dwellings_adobe_50km,
    exposure.urban_areas_50km
FROM seismic.event_population_exposure AS exposure
JOIN seismic.earthquake_event AS event USING (earthquake_event_id)
JOIN seismic.v_event_location_unique AS location USING (earthquake_event_id)
WHERE event.mw_homogenized >= 6
  AND event.occurred_at >= '1960-01-01'
ORDER BY exposure.population_50km DESC
LIMIT 10;

-- 13. Ciudades (las conurbaciones como una sola) con mas sismos Mw>=5 a
-- 100 km o menos del hipocentro.
WITH city AS (
    SELECT
        urban_area_id,
        coalesce(conurbation, name) AS city_name,
        sum(population) OVER (PARTITION BY coalesce(conurbation, name)) AS city_population
    FROM seismic.urban_area
    WHERE category = 'ciudad'
)
SELECT
    city.city_name,
    city.city_population,
    count(DISTINCT link.earthquake_event_id) AS earthquakes_mw5_within_100km,
    min(link.hypocentral_distance_km) AS closest_hypocentre_km
FROM seismic.event_urban_area AS link
JOIN city ON city.urban_area_id = link.urban_area_id
JOIN seismic.earthquake_event AS event ON event.earthquake_event_id = link.earthquake_event_id
WHERE event.mw_homogenized >= 5
  AND link.hypocentral_distance_km <= 100
  AND NOT EXISTS (SELECT 1 FROM seismic.event_match AS pair WHERE pair.usgs_event_id = event.earthquake_event_id)
GROUP BY city.city_name, city.city_population
ORDER BY earthquakes_mw5_within_100km DESC
LIMIT 10;

-- 14. Comuna versus ciudad: de los sismos Mw>=5 con epicentro dentro de la
-- comuna (consulta 3), cuantos caen dentro de una zona urbana.
SELECT
    location.commune_name,
    count(*) AS mw5_inside_commune,
    count(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM seismic.event_urban_area AS link
        WHERE link.earthquake_event_id = location.earthquake_event_id
          AND link.epicentral_distance_km = 0
    )) AS mw5_inside_urban_area,
    round(avg(location.depth_km)) AS avg_depth_km,
    round(commune.official_area_km2) AS commune_km2,
    (SELECT round(sum(urban.area_km2), 1) FROM seismic.urban_area AS urban
      WHERE urban.commune_area_id = commune.administrative_area_id) AS urban_km2
FROM seismic.v_event_location_unique AS location
JOIN seismic.administrative_area AS commune
  ON commune.level = 'commune'
 AND commune.official_code = location.commune_code
WHERE location.assignment_method = 'covers'
  AND location.mw_homogenized >= 5
GROUP BY location.commune_name, commune.administrative_area_id, commune.official_area_km2
ORDER BY mw5_inside_commune DESC
LIMIT 10;


-- 15. Actividad sismica de una comuna en una ventana de tiempo:
-- sismos con epicentro en la comuna de Calama en los ultimos 3 meses de
-- datos, por mes. La ventana termina en el sismo CSN mas reciente cargado (no
-- en now()), para que el resultado no dependa del dia en que se ejecuta ni de
-- que USGS se haya descargado despues que el CSN.
-- Cambiando comuna y ventana sirve para cualquier comuna y periodo.
WITH params AS (
    SELECT 'Calama'::text AS comuna, interval '3 months' AS ventana
),
bounds AS (
    SELECT params.comuna,
           max(event.occurred_at) - params.ventana AS desde,
           max(event.occurred_at) AS hasta
    FROM seismic.earthquake_event AS event
    CROSS JOIN params
    WHERE event.source_code = 'csn'
    GROUP BY params.comuna, params.ventana
)
SELECT
    coalesce(to_char(date_trunc('month', location.occurred_at AT TIME ZONE 'UTC'), 'YYYY-MM'), 'Total') AS mes,
    count(*) AS sismos,
    count(*) FILTER (WHERE location.also_in_usgs) AS tambien_en_usgs,
    count(*) FILTER (WHERE location.source_code = 'usgs') AS solo_usgs,
    count(*) FILTER (WHERE location.mw_homogenized >= 4) AS mw4_o_mas,
    max(location.mw_homogenized) AS mw_max,
    round(avg(location.depth_km)) AS profundidad_media_km
FROM seismic.v_event_location_unique AS location
JOIN bounds ON location.commune_name = bounds.comuna
WHERE location.assignment_method = 'covers'
  AND location.occurred_at > bounds.desde
  AND location.occurred_at <= bounds.hasta
GROUP BY ROLLUP (date_trunc('month', location.occurred_at AT TIME ZONE 'UTC'))
ORDER BY date_trunc('month', location.occurred_at AT TIME ZONE 'UTC') NULLS LAST;


-- ---------------------------------------------------------------------------
-- Emparejamiento CSN-USGS (entrega 3; db/match_events.sql).
-- ---------------------------------------------------------------------------

-- 16. Cobertura de las dos fuentes por decada: de los sismos Mw >= 4,5 (un
-- registro por sismo), cuantos publican ambas, solo el CSN o solo USGS.
SELECT
    (extract(year FROM occurred_at)::int / 10) * 10 AS decada,
    count(*) AS sismos,
    count(*) FILTER (WHERE also_in_usgs) AS ambas_fuentes,
    count(*) FILTER (WHERE source_code = 'csn' AND NOT also_in_usgs) AS solo_csn,
    count(*) FILTER (WHERE source_code = 'usgs') AS solo_usgs
FROM seismic.v_event_location_unique
WHERE mw_homogenized >= 4.5
  AND occurred_at >= '1900-01-01'
GROUP BY 1
ORDER BY 1;

-- 17. Calidad del emparejamiento: diferencias de tiempo y distancia entre los
-- dos registros de un mismo sismo, por periodo.
SELECT
    CASE WHEN csn.occurred_at < '1990-01-01' THEN '1. antes de 1990'
         WHEN csn.occurred_at < '2025-06-24' THEN '2. 1990 a 2025 (historico CSN)'
         ELSE '3. desde 24-06-2025 (paginas diarias CSN)' END AS periodo,
    count(*) AS pares,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY pair.time_difference_s)::numeric, 1) AS dt_mediana_s,
    round(percentile_cont(0.95) WITHIN GROUP (ORDER BY pair.time_difference_s)::numeric, 1) AS dt_p95_s,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY pair.distance_km)::numeric, 1) AS km_mediana,
    round(percentile_cont(0.95) WITHIN GROUP (ORDER BY pair.distance_km)::numeric, 1) AS km_p95,
    round(avg(pair.match_score), 3) AS puntaje_medio
FROM seismic.event_match AS pair
JOIN seismic.earthquake_event AS csn ON csn.earthquake_event_id = pair.csn_event_id
GROUP BY 1
ORDER BY 1;

-- 18. Validacion cruzada del Mw homogeneo: en cada par, el Mw que calculamos
-- para el registro CSN contra el del registro USGS, por formula usada en el
-- CSN. Una diferencia media cercana a 0 indica que la formula deja al CSN en
-- la misma escala. Mlv se calibro con estos pares (2026-11-22).
SELECT
    csn.mw_method AS formula_csn,
    count(*) AS pares,
    round(avg(csn.mw_homogenized - usgs.mw_homogenized), 3) AS diferencia_media,
    round(stddev(csn.mw_homogenized - usgs.mw_homogenized), 3) AS desviacion
FROM seismic.event_match AS pair
JOIN seismic.earthquake_event AS csn ON csn.earthquake_event_id = pair.csn_event_id
JOIN seismic.earthquake_event AS usgs ON usgs.earthquake_event_id = pair.usgs_event_id
WHERE csn.mw_homogenized IS NOT NULL
  AND usgs.mw_homogenized IS NOT NULL
GROUP BY csn.mw_method
ORDER BY pares DESC;

-- 19. Sismos que solo publica USGS: donde estan respecto de Chile. Explica
-- por que no tienen par en el CSN.
SELECT
    CASE WHEN assignment_method = 'covers' THEN '1. dentro de una comuna'
         WHEN distance_km <= 100 THEN '2. a 100 km o menos de una comuna'
         WHEN distance_km <= 500 THEN '3. entre 100 y 500 km'
         ELSE '4. a mas de 500 km' END AS ubicacion,
    count(*) AS sismos_solo_usgs,
    count(*) FILTER (WHERE occurred_at < '1973-01-01') AS antes_de_1973,
    round(avg(mw_homogenized), 2) AS mw_medio
FROM seismic.v_event_location_unique
WHERE source_code = 'usgs'
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- Replicas (entrega 3; db/decluster_gardner_knopoff.sql y db/decluster_st_dbscan.sql).
-- Cada ejecucion de un metodo queda en declustering_run con sus parametros.
-- ---------------------------------------------------------------------------

-- 25. Resumen de cada ejecucion: cuantos sismos quedan como principales,
-- replicas, precursores e independientes, y que fraccion del catalogo queda
-- al quitar las replicas y precursores (catalogo "desagrupado").
SELECT
    run.declustering_run_id AS run,
    run.method AS metodo,
    coalesce(run.source_code, 'csn+usgs') AS catalogo,
    coalesce(run.parameters ->> 'ventana_precursores_dias',
             (run.parameters ->> 'eps_km') || ' km · ' || (run.parameters ->> 'eps_dias') || ' d') AS parametro,
    count(*) AS sismos,
    count(*) FILTER (WHERE role.role = 'mainshock') AS principales,
    count(*) FILTER (WHERE role.role = 'aftershock') AS replicas,
    count(*) FILTER (WHERE role.role = 'foreshock') AS precursores,
    count(*) FILTER (WHERE role.role = 'independent') AS independientes,
    round(100.0 * count(*) FILTER (WHERE role.role IN ('mainshock', 'independent')) / count(*), 1) AS pct_desagrupado
FROM seismic.declustering_run AS run
JOIN seismic.event_sequence_role AS role USING (declustering_run_id)
GROUP BY run.declustering_run_id, run.method, run.source_code, run.parameters
ORDER BY run.declustering_run_id;

-- 26. Los grandes terremotos segun cada ejecucion: replicas, mayor replica y
-- duracion de la secuencia.
SELECT
    main.occurred_at::date AS fecha,
    main.mw_homogenized AS mw,
    run.declustering_run_id AS run,
    run.method AS metodo,
    coalesce(run.source_code, 'csn+usgs') AS catalogo,
    sequence.aftershock_count AS replicas,
    sequence.foreshock_count AS precursores,
    sequence.largest_aftershock_magnitude AS mayor_replica,
    round(extract(epoch FROM sequence.ended_at - sequence.started_at) / 86400) AS dias
FROM seismic.seismic_sequence AS sequence
JOIN seismic.declustering_run AS run USING (declustering_run_id)
JOIN seismic.earthquake_event AS main ON main.earthquake_event_id = sequence.mainshock_event_id
WHERE main.mw_homogenized >= 7.8
  AND main.occurred_at >= '1960-01-01'
ORDER BY main.occurred_at, run.declustering_run_id;

-- 27. Ley de Bath: diferencia entre el sismo principal y su mayor replica en
-- las secuencias con principal Mw >= 6,5 (se espera ~1,2 en promedio).
SELECT
    run.declustering_run_id AS run,
    run.method AS metodo,
    coalesce(run.source_code, 'csn+usgs') AS catalogo,
    count(*) AS secuencias,
    round(avg(main.mw_homogenized - sequence.largest_aftershock_magnitude), 2) AS delta_m_medio,
    round((percentile_cont(0.5) WITHIN GROUP (
        ORDER BY main.mw_homogenized - sequence.largest_aftershock_magnitude))::numeric, 2) AS delta_m_mediana
FROM seismic.seismic_sequence AS sequence
JOIN seismic.declustering_run AS run USING (declustering_run_id)
JOIN seismic.earthquake_event AS main ON main.earthquake_event_id = sequence.mainshock_event_id
WHERE main.mw_homogenized >= 6.5
  AND sequence.largest_aftershock_magnitude IS NOT NULL
GROUP BY run.declustering_run_id, run.method, run.source_code
ORDER BY run.declustering_run_id;

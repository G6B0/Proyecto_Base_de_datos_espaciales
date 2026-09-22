\set ON_ERROR_STOP on

SET TIME ZONE 'UTC';

BEGIN;

CREATE TEMP TABLE import_csn (
    longitude double precision NOT NULL,
    latitude double precision NOT NULL,
    source text NOT NULL,
    source_event_id text NOT NULL,
    source_catalog_id text,
    occurred_at_utc timestamptz NOT NULL,
    updated_at_utc timestamptz,
    magnitude numeric,
    magnitude_type text,
    reported_magnitude numeric,
    reported_magnitude_type text,
    magnitude_error numeric,
    magnitude_agency text,
    depth_km numeric,
    author text,
    place text,
    review_status text,
    event_type text,
    source_url text
);

\copy import_csn FROM '__CSN_CSV__' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

CREATE TEMP TABLE import_usgs (
    longitude double precision NOT NULL,
    latitude double precision NOT NULL,
    source text NOT NULL,
    source_event_id text NOT NULL,
    occurred_at_utc timestamptz NOT NULL,
    updated_at_utc timestamptz,
    magnitude numeric,
    magnitude_type text,
    depth_km numeric,
    place text,
    review_status text,
    tsunami boolean,
    significance integer,
    felt_reports integer,
    station_count integer,
    azimuthal_gap_deg numeric,
    min_distance_deg numeric,
    rms_seconds numeric,
    horizontal_error_km numeric,
    depth_error_km numeric,
    magnitude_error numeric,
    network text,
    location_source text,
    magnitude_source text,
    event_type text,
    source_url text
);

\copy import_usgs FROM '__USGS_CSV__' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

CREATE TEMP TABLE existing_csn AS
SELECT staged.source_event_id
FROM import_csn AS staged
JOIN seismic.earthquake_event AS event
  ON event.source_code = 'csn'
 AND event.source_event_id = staged.source_event_id;

CREATE TEMP TABLE existing_usgs AS
SELECT staged.source_event_id
FROM import_usgs AS staged
JOIN seismic.earthquake_event AS event
  ON event.source_code = 'usgs'
 AND event.source_event_id = staged.source_event_id;

INSERT INTO seismic.ingestion_run (
    source_code,
    requested_start,
    requested_end,
    received_events,
    status,
    details
)
SELECT
    'csn',
    min(occurred_at_utc),
    max(occurred_at_utc),
    count(*),
    'running',
    jsonb_build_object(
        'file', '__CSN_CSV__',
        'mode', 'upsert'
    )
FROM import_csn
RETURNING ingestion_run_id AS csn_ingestion_run_id \gset

INSERT INTO seismic.ingestion_run (
    source_code,
    requested_start,
    requested_end,
    minimum_magnitude,
    received_events,
    status,
    details
)
SELECT
    'usgs',
    min(occurred_at_utc),
    max(occurred_at_utc),
    min(magnitude),
    count(*),
    'running',
    jsonb_build_object(
        'file', '__USGS_CSV__',
        'mode', 'upsert'
    )
FROM import_usgs
RETURNING ingestion_run_id AS usgs_ingestion_run_id \gset

INSERT INTO seismic.earthquake_event (
    source_code,
    source_event_id,
    source_catalog_id,
    occurred_at,
    source_updated_at,
    magnitude,
    magnitude_type,
    reported_magnitude,
    reported_magnitude_type,
    magnitude_agency,
    author,
    depth_km,
    place,
    review_status,
    magnitude_error,
    event_type,
    source_url,
    geom,
    raw_data
)
SELECT
    'csn',
    source_event_id,
    source_catalog_id,
    occurred_at_utc,
    updated_at_utc,
    magnitude,
    magnitude_type,
    reported_magnitude,
    reported_magnitude_type,
    magnitude_agency,
    author,
    depth_km,
    place,
    review_status,
    magnitude_error,
    coalesce(event_type, 'earthquake'),
    source_url,
    ST_SetSRID(ST_MakePoint(longitude, latitude), 4326),
    jsonb_strip_nulls(jsonb_build_object(
        'source', source,
        'source_catalog_id', source_catalog_id,
        'reported_magnitude', reported_magnitude,
        'reported_magnitude_type', reported_magnitude_type,
        'magnitude_agency', magnitude_agency,
        'author', author,
        'place', place,
        'source_url', source_url
    ))
FROM import_csn
ON CONFLICT (source_code, source_event_id) DO UPDATE SET
    source_catalog_id = EXCLUDED.source_catalog_id,
    occurred_at = EXCLUDED.occurred_at,
    source_updated_at = EXCLUDED.source_updated_at,
    magnitude = EXCLUDED.magnitude,
    magnitude_type = EXCLUDED.magnitude_type,
    reported_magnitude = EXCLUDED.reported_magnitude,
    reported_magnitude_type = EXCLUDED.reported_magnitude_type,
    magnitude_agency = EXCLUDED.magnitude_agency,
    author = EXCLUDED.author,
    depth_km = EXCLUDED.depth_km,
    place = EXCLUDED.place,
    review_status = EXCLUDED.review_status,
    magnitude_error = EXCLUDED.magnitude_error,
    event_type = EXCLUDED.event_type,
    source_url = EXCLUDED.source_url,
    geom = EXCLUDED.geom,
    raw_data = EXCLUDED.raw_data,
    last_seen_at = now();

INSERT INTO seismic.earthquake_event (
    source_code,
    source_event_id,
    occurred_at,
    source_updated_at,
    magnitude,
    magnitude_type,
    depth_km,
    place,
    review_status,
    tsunami,
    significance,
    felt_reports,
    station_count,
    azimuthal_gap_deg,
    min_distance_deg,
    rms_seconds,
    horizontal_error_km,
    depth_error_km,
    magnitude_error,
    network,
    location_source,
    magnitude_source,
    event_type,
    source_url,
    geom,
    raw_data
)
SELECT
    'usgs',
    source_event_id,
    occurred_at_utc,
    updated_at_utc,
    magnitude,
    magnitude_type,
    depth_km,
    place,
    review_status,
    coalesce(tsunami, false),
    significance,
    felt_reports,
    station_count,
    azimuthal_gap_deg,
    min_distance_deg,
    rms_seconds,
    horizontal_error_km,
    depth_error_km,
    magnitude_error,
    network,
    location_source,
    magnitude_source,
    coalesce(event_type, 'earthquake'),
    source_url,
    ST_SetSRID(ST_MakePoint(longitude, latitude), 4326),
    jsonb_strip_nulls(jsonb_build_object(
        'source', source,
        'place', place,
        'network', network,
        'location_source', location_source,
        'magnitude_source', magnitude_source,
        'source_url', source_url
    ))
FROM import_usgs
ON CONFLICT (source_code, source_event_id) DO UPDATE SET
    occurred_at = EXCLUDED.occurred_at,
    source_updated_at = EXCLUDED.source_updated_at,
    magnitude = EXCLUDED.magnitude,
    magnitude_type = EXCLUDED.magnitude_type,
    depth_km = EXCLUDED.depth_km,
    place = EXCLUDED.place,
    review_status = EXCLUDED.review_status,
    tsunami = EXCLUDED.tsunami,
    significance = EXCLUDED.significance,
    felt_reports = EXCLUDED.felt_reports,
    station_count = EXCLUDED.station_count,
    azimuthal_gap_deg = EXCLUDED.azimuthal_gap_deg,
    min_distance_deg = EXCLUDED.min_distance_deg,
    rms_seconds = EXCLUDED.rms_seconds,
    horizontal_error_km = EXCLUDED.horizontal_error_km,
    depth_error_km = EXCLUDED.depth_error_km,
    magnitude_error = EXCLUDED.magnitude_error,
    network = EXCLUDED.network,
    location_source = EXCLUDED.location_source,
    magnitude_source = EXCLUDED.magnitude_source,
    event_type = EXCLUDED.event_type,
    source_url = EXCLUDED.source_url,
    geom = EXCLUDED.geom,
    raw_data = EXCLUDED.raw_data,
    last_seen_at = now();

UPDATE seismic.ingestion_run
SET
    finished_at = now(),
    inserted_events = (SELECT count(*) FROM import_csn) - (SELECT count(*) FROM existing_csn),
    updated_events = (SELECT count(*) FROM existing_csn),
    status = 'completed'
WHERE ingestion_run_id = :csn_ingestion_run_id;

UPDATE seismic.ingestion_run
SET
    finished_at = now(),
    inserted_events = (SELECT count(*) FROM import_usgs) - (SELECT count(*) FROM existing_usgs),
    updated_events = (SELECT count(*) FROM existing_usgs),
    status = 'completed'
WHERE ingestion_run_id = :usgs_ingestion_run_id;

ANALYZE seismic.earthquake_event;

COMMIT;

SELECT
    source_code,
    count(*) AS events,
    min(occurred_at) AS earliest_event,
    max(occurred_at) AS latest_event,
    min(magnitude) AS minimum_magnitude,
    max(magnitude) AS maximum_magnitude
FROM seismic.earthquake_event
GROUP BY source_code
ORDER BY source_code;

SELECT
    ingestion_run_id,
    source_code,
    received_events,
    inserted_events,
    updated_events,
    status,
    finished_at
FROM seismic.ingestion_run
ORDER BY ingestion_run_id DESC
LIMIT 2;

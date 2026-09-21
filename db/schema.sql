CREATE EXTENSION IF NOT EXISTS postgis;

DO $$
BEGIN
    EXECUTE format(
        'ALTER DATABASE %I SET timezone TO %L',
        current_database(),
        'UTC'
    );
END
$$;

SET TIME ZONE 'UTC';

CREATE SCHEMA IF NOT EXISTS seismic;

CREATE TABLE IF NOT EXISTS seismic.data_source (
    source_code text PRIMARY KEY,
    source_name text NOT NULL,
    homepage_url text NOT NULL,
    citation text,
    is_near_real_time boolean NOT NULL DEFAULT false
);

INSERT INTO seismic.data_source (
    source_code,
    source_name,
    homepage_url,
    citation,
    is_near_real_time
)
VALUES
    (
        'usgs',
        'USGS ANSS Comprehensive Earthquake Catalog',
        'https://earthquake.usgs.gov/fdsnws/event/1/',
        'U.S. Geological Survey',
        true
    ),
    (
        'csn',
        'Centro Sismologico Nacional de la Universidad de Chile',
        'https://www.sismologia.cl/',
        'Centro Sismologico Nacional de la Universidad de Chile',
        true
    ),
    (
        'isc',
        'International Seismological Centre Bulletin',
        'https://www.isc.ac.uk/iscbulletin/',
        'International Seismological Centre',
        false
    )
ON CONFLICT (source_code) DO UPDATE SET
    source_name = EXCLUDED.source_name,
    homepage_url = EXCLUDED.homepage_url,
    citation = EXCLUDED.citation,
    is_near_real_time = EXCLUDED.is_near_real_time;

CREATE TABLE IF NOT EXISTS seismic.ingestion_run (
    ingestion_run_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_code text NOT NULL REFERENCES seismic.data_source (source_code),
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    requested_start timestamptz,
    requested_end timestamptz,
    minimum_magnitude numeric(4, 2),
    received_events integer,
    inserted_events integer,
    updated_events integer,
    status text NOT NULL DEFAULT 'running'
        CHECK (status IN ('running', 'completed', 'failed')),
    details jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS seismic.earthquake_event (
    earthquake_event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_code text NOT NULL REFERENCES seismic.data_source (source_code),
    source_event_id text NOT NULL,
    source_catalog_id text,
    occurred_at timestamptz NOT NULL,
    source_updated_at timestamptz,
    magnitude numeric(5, 2),
    magnitude_type text,
    reported_magnitude numeric(5, 2),
    reported_magnitude_type text,
    magnitude_agency text,
    author text,
    depth_km numeric(8, 3),
    place text,
    review_status text,
    tsunami boolean NOT NULL DEFAULT false,
    significance integer,
    felt_reports integer,
    station_count integer,
    azimuthal_gap_deg numeric(7, 3),
    min_distance_deg numeric(9, 5),
    rms_seconds numeric(8, 4),
    horizontal_error_km numeric(9, 3),
    depth_error_km numeric(9, 3),
    magnitude_error numeric(7, 3),
    network text,
    location_source text,
    magnitude_source text,
    event_type text NOT NULL DEFAULT 'earthquake',
    source_url text,
    geom geometry(Point, 4326) NOT NULL,
    raw_data jsonb NOT NULL DEFAULT '{}'::jsonb,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT earthquake_event_source_id_unique
        UNIQUE (source_code, source_event_id),
    CONSTRAINT earthquake_event_longitude_check
        CHECK (ST_X(geom) BETWEEN -180 AND 180),
    CONSTRAINT earthquake_event_latitude_check
        CHECK (ST_Y(geom) BETWEEN -90 AND 90),
    CONSTRAINT earthquake_event_depth_check
        CHECK (depth_km IS NULL OR depth_km BETWEEN -10 AND 800)
);

CREATE INDEX IF NOT EXISTS earthquake_event_geom_gix
    ON seismic.earthquake_event USING gist (geom);

CREATE INDEX IF NOT EXISTS earthquake_event_occurred_at_idx
    ON seismic.earthquake_event (occurred_at DESC);

CREATE INDEX IF NOT EXISTS earthquake_event_magnitude_idx
    ON seismic.earthquake_event (magnitude DESC)
    WHERE magnitude IS NOT NULL;

CREATE TABLE IF NOT EXISTS seismic.administrative_area (
    administrative_area_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    level text NOT NULL CHECK (level IN ('country', 'region', 'province', 'commune')),
    official_code text NOT NULL,
    name text NOT NULL,
    source text NOT NULL,
    geom geometry(MultiPolygon, 4326) NOT NULL,
    CONSTRAINT administrative_area_level_code_unique UNIQUE (level, official_code)
);

CREATE INDEX IF NOT EXISTS administrative_area_geom_gix
    ON seismic.administrative_area USING gist (geom);

CREATE TABLE IF NOT EXISTS seismic.event_administrative_area (
    earthquake_event_id bigint NOT NULL
        REFERENCES seismic.earthquake_event (earthquake_event_id) ON DELETE CASCADE,
    administrative_area_id bigint NOT NULL
        REFERENCES seismic.administrative_area (administrative_area_id) ON DELETE CASCADE,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (earthquake_event_id, administrative_area_id)
);

COMMENT ON COLUMN seismic.earthquake_event.geom IS
    'Two-dimensional epicentre in EPSG:4326; hypocentral depth is stored in depth_km.';

COMMENT ON COLUMN seismic.earthquake_event.magnitude IS
    'Magnitude value from the source; compare together with magnitude_type.';

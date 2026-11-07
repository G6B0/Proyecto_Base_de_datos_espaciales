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
    ),
    (
        'dpa',
        'Division Politico Administrativa 2023 (IDE Chile / SUBDERE)',
        'https://www.ide.cl/',
        'SUBDERE, IGM, DIFROL e INE. Division Politico Administrativa 2023. '
            'Autorizada su circulacion por Resolucion N 87 del 2023 de DIFROL.',
        false
    ),
    (
        'ine',
        'Cartografia censal Censo de Poblacion y Vivienda 2024 (INE)',
        'https://censo2024.ine.gob.cl/resultados/',
        'Instituto Nacional de Estadisticas (INE). Censo de Poblacion y '
            'Vivienda 2024, Base Cartografica Censal (publicada 2025-12-16).',
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

-- Modelo v2 (Entrega 2): jerarquia region > provincia > comuna y datos
-- oficiales de la DPA 2023. Se agregan con ALTER para que el script sea
-- idempotente sobre una base ya creada con el modelo v1.
ALTER TABLE seismic.administrative_area
    ADD COLUMN IF NOT EXISTS parent_area_id bigint
        REFERENCES seismic.administrative_area (administrative_area_id),
    ADD COLUMN IF NOT EXISTS official_area_km2 numeric(12, 2),
    ADD COLUMN IF NOT EXISTS source_version text,
    ADD COLUMN IF NOT EXISTS loaded_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS administrative_area_parent_idx
    ON seismic.administrative_area (parent_area_id);

-- Tabla tecnica: cada poligono oficial se corta en trozos de hasta 255
-- vertices (ST_Subdivide). Las consultas punto-en-poligono contra trozos
-- pequenos son mucho mas rapidas que contra los poligonos 1:50.000 completos.
-- Se regenera completa en cada carga de la DPA; no es un dato de negocio.
CREATE TABLE IF NOT EXISTS seismic.administrative_area_part (
    administrative_area_part_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    administrative_area_id bigint NOT NULL
        REFERENCES seismic.administrative_area (administrative_area_id) ON DELETE CASCADE,
    geom geometry(Polygon, 4326) NOT NULL
);

CREATE INDEX IF NOT EXISTS administrative_area_part_geom_gix
    ON seismic.administrative_area_part USING gist (geom);

CREATE INDEX IF NOT EXISTS administrative_area_part_area_idx
    ON seismic.administrative_area_part (administrative_area_id);

CREATE TABLE IF NOT EXISTS seismic.event_administrative_area (
    earthquake_event_id bigint NOT NULL
        REFERENCES seismic.earthquake_event (earthquake_event_id) ON DELETE CASCADE,
    administrative_area_id bigint NOT NULL
        REFERENCES seismic.administrative_area (administrative_area_id) ON DELETE CASCADE,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (earthquake_event_id, administrative_area_id)
);

-- Modelo v2: cada evento se asigna a UNA comuna. Si el epicentro cae dentro
-- de una comuna se usa 'covers' (distancia 0). Si cae en el mar o fuera de
-- Chile se usa la comuna mas cercana ('nearest') y se guarda la distancia.
ALTER TABLE seismic.event_administrative_area
    ADD COLUMN IF NOT EXISTS assignment_method text NOT NULL DEFAULT 'covers',
    ADD COLUMN IF NOT EXISTS distance_km numeric(9, 3) NOT NULL DEFAULT 0;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'event_administrative_area_method_check'
    ) THEN
        ALTER TABLE seismic.event_administrative_area
            ADD CONSTRAINT event_administrative_area_method_check
            CHECK (assignment_method IN ('covers', 'nearest'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'event_administrative_area_distance_check'
    ) THEN
        ALTER TABLE seismic.event_administrative_area
            ADD CONSTRAINT event_administrative_area_distance_check
            CHECK (
                distance_km >= 0
                AND (assignment_method = 'nearest' OR distance_km = 0)
            );
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS event_administrative_area_event_uidx
    ON seismic.event_administrative_area (earthquake_event_id);

CREATE INDEX IF NOT EXISTS event_administrative_area_area_idx
    ON seismic.event_administrative_area (administrative_area_id);

-- Modelo v2: magnitudes homogeneas. Explicacion completa en docs/MAGNITUDES.md.
-- Las fuentes publican escalas distintas (MWconv, Ml, Mlv, mb, Mww...). Estas
-- tablas describen cada escala, guardan las formulas de conversion a Mw como
-- datos y dicen que formula usar para cada fuente + tipo.
CREATE TABLE IF NOT EXISTS seismic.magnitude_type (
    magnitude_type_code text PRIMARY KEY
        CHECK (magnitude_type_code = lower(magnitude_type_code)),
    family text NOT NULL CHECK (family IN (
        'moment', 'converted', 'local', 'duration',
        'body_wave', 'surface_wave', 'unknown'
    )),
    is_moment_magnitude boolean NOT NULL,
    saturation_magnitude numeric(3, 1),
    name_es text NOT NULL,
    description text NOT NULL
);

INSERT INTO seismic.magnitude_type (
    magnitude_type_code, family, is_moment_magnitude,
    saturation_magnitude, name_es, description
)
VALUES
    ('mw', 'moment', true, NULL, 'Magnitud de momento',
     'Calculada desde el momento sismico (rigidez x area x deslizamiento). No se satura. Escala de referencia.'),
    ('mww', 'moment', true, NULL, 'Magnitud de momento (fase W)',
     'Mw calculada con la fase W, onda de periodo muy largo. Estandar para sismos grandes.'),
    ('mwr', 'moment', true, NULL, 'Magnitud de momento (tensor regional)',
     'Mw calculada con un tensor de momento de estaciones regionales. Tipica para M 3,5 a 6.'),
    ('mwc', 'moment', true, NULL, 'Magnitud de momento (tensor centroide)',
     'Mw calculada con ondas largas globales, estilo Global CMT.'),
    ('mwb', 'moment', true, NULL, 'Magnitud de momento (ondas de cuerpo)',
     'Mw calculada con un tensor de momento de ondas de cuerpo.'),
    ('mwconv', 'converted', true, NULL, 'Mw convertida por el CSN',
     'Columna MWconv del catalogo historico CSN: magnitud original (mb, ML, Md, Ms o Mw) convertida a Mw con formulas lineales.'),
    ('ml', 'local', false, 6.5, 'Magnitud local (Richter)',
     'Amplitud maxima en un sismografo cercano corregida por distancia (Richter, 1935). Se satura sobre ~6,5.'),
    ('mlv', 'local', false, 6.5, 'Magnitud local, componente vertical',
     'Magnitud local medida en la componente vertical del sismografo. El CSN la usa desde 2026 en lugar de Ml.'),
    ('mlh', 'local', false, 6.5, 'Magnitud local, componente horizontal',
     'Magnitud local medida en la componente horizontal, como la definio Richter.'),
    ('md', 'duration', false, 5.0, 'Magnitud de duracion',
     'Basada en la duracion de la senal. Solo para sismos chicos; valor de saturacion aproximado.'),
    ('mb', 'body_wave', false, 6.0, 'Magnitud de ondas de cuerpo',
     'Amplitud de la onda P (~1 s) en estaciones lejanas. Se satura entre 6 y 6,5. Cada agencia la mide distinto.'),
    ('ms', 'surface_wave', false, 8.0, 'Magnitud de ondas superficiales',
     'Amplitud de ondas Rayleigh de ~20 s en estaciones lejanas. Se satura cerca de 8.'),
    ('m', 'unknown', false, NULL, 'Magnitud sin tipo',
     'La fuente no declara la escala. No se convierte.')
ON CONFLICT (magnitude_type_code) DO UPDATE SET
    family = EXCLUDED.family,
    is_moment_magnitude = EXCLUDED.is_moment_magnitude,
    saturation_magnitude = EXCLUDED.saturation_magnitude,
    name_es = EXCLUDED.name_es,
    description = EXCLUDED.description;

-- Formulas Mw = slope * magnitud + intercept, validas entre valid_min y
-- valid_max (NULL = sin limite). Las relaciones csn_relation_* se dedujeron
-- del propio catalogo historico CSN (MWconv vs magnitud original); ver
-- docs/MAGNITUDES.md seccion 6. No se extrapola fuera del rango.
CREATE TABLE IF NOT EXISTS seismic.magnitude_conversion (
    conversion_method text PRIMARY KEY,
    slope numeric(6, 4) NOT NULL,
    intercept numeric(6, 4) NOT NULL,
    valid_min numeric(3, 1),
    valid_max numeric(3, 1),
    is_provisional boolean NOT NULL DEFAULT false,
    reference text NOT NULL,
    CONSTRAINT magnitude_conversion_range_check
        CHECK (valid_min IS NULL OR valid_max IS NULL OR valid_min <= valid_max)
);

INSERT INTO seismic.magnitude_conversion (
    conversion_method, slope, intercept, valid_min, valid_max,
    is_provisional, reference
)
VALUES
    ('native', 1, 0, NULL, NULL, false,
     'La magnitud publicada ya es Mw (Hanks y Kanamori, 1979).'),
    ('csn_mwconv', 1, 0, NULL, NULL, false,
     'Catalogo historico CSN: MWconv ya esta convertida a Mw por el CSN.'),
    ('csn_relation_mb_neic', 1.1504, -0.7327, 4.1, 6.1, false,
     'Relacion usada por el CSN para mb de NEIC/USGS: 5.013 eventos 1964-2025, error maximo 0,006.'),
    ('csn_relation_ms_neic', 0.6801, 2.0390, 3.8, 5.9, false,
     'Relacion usada por el CSN para Ms de NEIC: 57 eventos 1969-2000; casi igual a Scordilis (2006).'),
    ('csn_relation_ml', 0.9575, 0.2412, 4.0, 5.4, false,
     'Relacion usada por el CSN para ML de la U. de Chile: 4.602 eventos 2001-2025. Validada para el Ml diario: es el mismo ML (77 de 84 identicos) y el residuo contra MWconv es +0,008 +/- 0,145 (315 pares).'),
    ('csn_relation_mlv_provisional', 0.9575, 0.2412, 4.0, 5.4, true,
     'Misma relacion aplicada a Mlv/Mlh, que el CSN usa desde 2026. Contra mb de USGS convertido el residuo es -0,035 +/- 0,20 (147 pares), pero contra mwr sugiere que Mlv queda ~0,1 alto. Provisional.')
ON CONFLICT (conversion_method) DO UPDATE SET
    slope = EXCLUDED.slope,
    intercept = EXCLUDED.intercept,
    valid_min = EXCLUDED.valid_min,
    valid_max = EXCLUDED.valid_max,
    is_provisional = EXCLUDED.is_provisional,
    reference = EXCLUDED.reference;

-- Que formula usar para cada fuente + tipo. Un tipo sin regla (m, md, ml de
-- USGS...) queda sin Mw homogeneo.
CREATE TABLE IF NOT EXISTS seismic.magnitude_conversion_rule (
    source_code text NOT NULL REFERENCES seismic.data_source (source_code),
    magnitude_type_code text NOT NULL
        REFERENCES seismic.magnitude_type (magnitude_type_code),
    conversion_method text NOT NULL
        REFERENCES seismic.magnitude_conversion (conversion_method),
    PRIMARY KEY (source_code, magnitude_type_code)
);

INSERT INTO seismic.magnitude_conversion_rule (
    source_code, magnitude_type_code, conversion_method
)
VALUES
    ('csn', 'mwconv', 'csn_mwconv'),
    ('csn', 'mw', 'native'),
    ('csn', 'mww', 'native'),
    ('csn', 'mb', 'csn_relation_mb_neic'),
    ('csn', 'ml', 'csn_relation_ml'),
    ('csn', 'mlv', 'csn_relation_mlv_provisional'),
    ('csn', 'mlh', 'csn_relation_mlv_provisional'),
    ('usgs', 'mw', 'native'),
    ('usgs', 'mww', 'native'),
    ('usgs', 'mwr', 'native'),
    ('usgs', 'mwc', 'native'),
    ('usgs', 'mwb', 'native'),
    ('usgs', 'mb', 'csn_relation_mb_neic'),
    ('usgs', 'ms', 'csn_relation_ms_neic')
ON CONFLICT (source_code, magnitude_type_code) DO UPDATE SET
    conversion_method = EXCLUDED.conversion_method;

-- Mw homogeneo de cada evento y la formula que lo produjo. La columna
-- magnitude (valor publicado por la fuente) no se modifica nunca.
ALTER TABLE seismic.earthquake_event
    ADD COLUMN IF NOT EXISTS mw_homogenized numeric(4, 2),
    ADD COLUMN IF NOT EXISTS mw_method text
        REFERENCES seismic.magnitude_conversion (conversion_method);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'earthquake_event_mw_check'
    ) THEN
        ALTER TABLE seismic.earthquake_event
            ADD CONSTRAINT earthquake_event_mw_check
            CHECK ((mw_homogenized IS NULL) = (mw_method IS NULL));
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS earthquake_event_mw_idx
    ON seismic.earthquake_event (mw_homogenized DESC)
    WHERE mw_homogenized IS NOT NULL;

-- 2026-11-06: tras la validacion (docs/MAGNITUDES.md seccion 10) el metodo
-- unico csn_relation_ml_provisional se separo en csn_relation_ml (validado)
-- y csn_relation_mlv_provisional. La formula es la misma; solo cambia la
-- etiqueta. Sin efecto en una base nueva o ya migrada.
UPDATE seismic.earthquake_event
SET mw_method = CASE lower(magnitude_type)
        WHEN 'ml' THEN 'csn_relation_ml'
        ELSE 'csn_relation_mlv_provisional'
    END
WHERE mw_method = 'csn_relation_ml_provisional';

DELETE FROM seismic.magnitude_conversion
WHERE conversion_method = 'csn_relation_ml_provisional';

-- Vista de lectura: un evento con su comuna, provincia y region.
CREATE OR REPLACE VIEW seismic.v_event_location AS
SELECT
    event.earthquake_event_id,
    event.source_code,
    event.source_event_id,
    event.occurred_at,
    event.magnitude,
    event.magnitude_type,
    event.depth_km,
    link.assignment_method,
    link.distance_km,
    commune.official_code AS commune_code,
    commune.name AS commune_name,
    province.official_code AS province_code,
    province.name AS province_name,
    region.official_code AS region_code,
    region.name AS region_name,
    event.geom,
    -- Agregadas al final: CREATE OR REPLACE VIEW solo permite sumar columnas.
    event.mw_homogenized,
    event.mw_method
FROM seismic.earthquake_event AS event
LEFT JOIN seismic.event_administrative_area AS link
       ON link.earthquake_event_id = event.earthquake_event_id
LEFT JOIN seismic.administrative_area AS commune
       ON commune.administrative_area_id = link.administrative_area_id
LEFT JOIN seismic.administrative_area AS province
       ON province.administrative_area_id = commune.parent_area_id
LEFT JOIN seismic.administrative_area AS region
       ON region.administrative_area_id = province.parent_area_id;

COMMENT ON TABLE seismic.administrative_area IS
    'Regiones, provincias y comunas de la DPA 2023 (EPSG:4326). parent_area_id: comuna->provincia->region.';
COMMENT ON TABLE seismic.administrative_area_part IS
    'Trozos (ST_Subdivide) de administrative_area para acelerar consultas espaciales. Derivada; se regenera.';
COMMENT ON TABLE seismic.event_administrative_area IS
    'Comuna asignada a cada evento. covers = epicentro dentro; nearest = comuna mas cercana (mar o extranjero) con distance_km.';

COMMENT ON COLUMN seismic.earthquake_event.geom IS
    'Two-dimensional epicentre in EPSG:4326; hypocentral depth is stored in depth_km.';

COMMENT ON COLUMN seismic.earthquake_event.magnitude IS
    'Magnitude value from the source; compare together with magnitude_type.';

COMMENT ON COLUMN seismic.earthquake_event.mw_homogenized IS
    'Mw estimado para comparar fuentes y periodos (db/homogenize_magnitudes.sql). NULL si no hay formula confiable.';
COMMENT ON COLUMN seismic.earthquake_event.mw_method IS
    'Formula usada para mw_homogenized (seismic.magnitude_conversion).';
COMMENT ON TABLE seismic.magnitude_type IS
    'Tipos de magnitud: familia, saturacion y explicacion. Ver docs/MAGNITUDES.md.';
COMMENT ON TABLE seismic.magnitude_conversion IS
    'Formulas Mw = slope * m + intercept con su rango valido y su origen.';
COMMENT ON TABLE seismic.magnitude_conversion_rule IS
    'Formula de conversion a usar para cada fuente + tipo de magnitud.';

-- ---------------------------------------------------------------------------
-- Modelo v2: zonas urbanas y poblacion (Censo 2024, INE). Explicacion completa
-- en docs/INE_CENSO2024.md y docs/MODELO_LOGICO_v2.md.
-- La comuna cubre todo el territorio (ciudad, campo, cordillera, desierto);
-- estas tablas dicen DONDE vive la gente dentro de ella.
--   urban_area   : ciudades y pueblos (capa Limite_Urbano_CPV24), con poblacion.
--   census_block : manzanas urbanas y de aldea (capa Manzanas_CPV24), con
--                  poblacion. Cubren el 87 % de la poblacion censada; la
--                  poblacion rural dispersa no vive en manzanas.
-- Se cargan con scripts/load_ine_manzanas_postgis.ps1 + db/load_census.sql.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS seismic.urban_area (
    urban_area_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ine_entity_id bigint NOT NULL,
    name text NOT NULL,
    category text NOT NULL CHECK (category IN ('ciudad', 'pueblo')),
    locality_name text,
    conurbation text,
    commune_area_id bigint NOT NULL
        REFERENCES seismic.administrative_area (administrative_area_id),
    population integer NOT NULL CHECK (population >= 0),
    population_0_5 integer,
    population_60_plus integer,
    population_disability integer,
    households integer,
    private_dwellings integer,
    dwellings_adobe integer,
    dwellings_precarious integer,
    area_km2 numeric(10, 3) NOT NULL,
    source_version text NOT NULL,
    loaded_at timestamptz NOT NULL DEFAULT now(),
    geom geometry(MultiPolygon, 4326) NOT NULL,
    CONSTRAINT urban_area_ine_entity_unique UNIQUE (ine_entity_id)
);

CREATE INDEX IF NOT EXISTS urban_area_geom_gix
    ON seismic.urban_area USING gist (geom);

CREATE INDEX IF NOT EXISTS urban_area_commune_idx
    ON seismic.urban_area (commune_area_id);

-- Tabla tecnica, igual que administrative_area_part: las zonas urbanas
-- suman 888 mil vertices (una sola llega a 58 mil) y medir distancias contra
-- ellas completas es lento. Se cortan en trozos de hasta 255 vertices.
-- Se regenera en cada carga del censo; no es un dato de negocio.
CREATE TABLE IF NOT EXISTS seismic.urban_area_part (
    urban_area_part_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    urban_area_id bigint NOT NULL
        REFERENCES seismic.urban_area (urban_area_id) ON DELETE CASCADE,
    geom geometry(Polygon, 4326) NOT NULL
);

CREATE INDEX IF NOT EXISTS urban_area_part_geom_gix
    ON seismic.urban_area_part USING gist (geom);

-- 2026-11-07: los indices sobre geography de zonas urbanas no se usan
-- (db/assign_urban_exposure.sql filtra con el indice geometrico y mide en dos
-- etapas). Se eliminan en bases creadas antes.
DROP INDEX IF EXISTS seismic.urban_area_geog_gix;
DROP INDEX IF EXISTS seismic.urban_area_part_geog_gix;

CREATE INDEX IF NOT EXISTS urban_area_part_area_idx
    ON seismic.urban_area_part (urban_area_id);

CREATE TABLE IF NOT EXISTS seismic.census_block (
    census_block_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    block_code bigint NOT NULL,
    block_type text NOT NULL CHECK (block_type IN ('urbano', 'aldea')),
    urban_area_id bigint
        REFERENCES seismic.urban_area (urban_area_id) ON DELETE SET NULL,
    commune_area_id bigint NOT NULL
        REFERENCES seismic.administrative_area (administrative_area_id),
    has_census_data boolean NOT NULL,
    population integer NOT NULL CHECK (population >= 0),
    population_60_plus integer,
    private_dwellings integer,
    dwellings_adobe integer,
    point geometry(Point, 4326) NOT NULL,
    geom geometry(MultiPolygon, 4326) NOT NULL,
    CONSTRAINT census_block_code_unique UNIQUE (block_code),
    -- Las manzanas urbanas pertenecen a una zona urbana; las de aldea no.
    CONSTRAINT census_block_urban_check
        CHECK ((block_type = 'urbano') = (urban_area_id IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS census_block_point_geog_gix
    ON seismic.census_block USING gist ((point::geography));

CREATE INDEX IF NOT EXISTS census_block_geom_gix
    ON seismic.census_block USING gist (geom);

CREATE INDEX IF NOT EXISTS census_block_urban_area_idx
    ON seismic.census_block (urban_area_id);

CREATE INDEX IF NOT EXISTS census_block_commune_idx
    ON seismic.census_block (commune_area_id);

-- Relacion N:M sismo <-> zona urbana (db/assign_urban_exposure.sql).
-- Regla: cada sismo guarda su zona urbana mas cercana (distance_rank = 1),
-- y los sismos con Mw >= 5 guardan ademas todas las zonas urbanas a 200 km
-- o menos del epicentro, ordenadas por distancia.
CREATE TABLE IF NOT EXISTS seismic.event_urban_area (
    earthquake_event_id bigint NOT NULL
        REFERENCES seismic.earthquake_event (earthquake_event_id) ON DELETE CASCADE,
    urban_area_id bigint NOT NULL
        REFERENCES seismic.urban_area (urban_area_id) ON DELETE CASCADE,
    distance_rank smallint NOT NULL CHECK (distance_rank >= 1),
    epicentral_distance_km numeric(9, 3) NOT NULL CHECK (epicentral_distance_km >= 0),
    hypocentral_distance_km numeric(9, 3)
        CHECK (hypocentral_distance_km >= epicentral_distance_km),
    PRIMARY KEY (earthquake_event_id, urban_area_id),
    CONSTRAINT event_urban_area_rank_unique UNIQUE (earthquake_event_id, distance_rank)
);

CREATE INDEX IF NOT EXISTS event_urban_area_urban_idx
    ON seismic.event_urban_area (urban_area_id);

-- Poblacion censada cerca de cada sismo Mw >= 5 (db/assign_urban_exposure.sql).
-- Cuenta las manzanas cuyo punto interior queda a la distancia indicada del
-- epicentro. Describe cuanta gente vive cerca; no estima dano ni intensidad.
CREATE TABLE IF NOT EXISTS seismic.event_population_exposure (
    earthquake_event_id bigint PRIMARY KEY
        REFERENCES seismic.earthquake_event (earthquake_event_id) ON DELETE CASCADE,
    population_25km integer NOT NULL,
    population_50km integer NOT NULL,
    population_100km integer NOT NULL,
    population_60_plus_50km integer NOT NULL,
    dwellings_adobe_50km integer NOT NULL,
    urban_areas_50km integer NOT NULL,
    computed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT event_population_exposure_order_check
        CHECK (population_25km <= population_50km
               AND population_50km <= population_100km)
);

COMMENT ON TABLE seismic.urban_area IS
    'Ciudades y pueblos del Censo 2024 (Limite_Urbano_CPV24) con poblacion. Una fila por entidad urbana; las conurbaciones (Gran Santiago...) se agrupan con conurbation.';
COMMENT ON TABLE seismic.urban_area_part IS
    'Trozos (ST_Subdivide) de urban_area para acelerar las distancias sismo-zona urbana. Derivada; se regenera.';
COMMENT ON COLUMN seismic.urban_area.dwellings_adobe IS
    'Viviendas con paredes de adobe, barro, pirca, quincha u otro material artesanal (n_mat_paredes_artesanal).';
COMMENT ON TABLE seismic.census_block IS
    'Manzanas urbanas y de aldea del Censo 2024 (Manzanas_CPV24). point = ST_PointOnSurface de la manzana.';
COMMENT ON COLUMN seismic.census_block.has_census_data IS
    'MZ_BASE_CENSO: false = manzana sin viviendas ni personas en los tabulados.';
COMMENT ON TABLE seismic.event_urban_area IS
    'Zonas urbanas cercanas a cada sismo: la mas cercana siempre (rank 1); todas a <= 200 km si Mw >= 5. Distancia al borde de la zona (0 si el epicentro esta dentro).';
COMMENT ON TABLE seismic.event_population_exposure IS
    'Poblacion y viviendas censadas (manzanas) a 25, 50 y 100 km del epicentro de cada sismo Mw >= 5. No es estimacion de dano.';

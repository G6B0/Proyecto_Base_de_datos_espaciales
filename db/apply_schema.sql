\set ON_ERROR_STOP on

-- Este archivo se ejecuta inicialmente contra la base administrativa
-- "postgres". Crea la base del proyecto solo cuando aun no existe.
SELECT 'CREATE DATABASE sismos_chile'
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = 'sismos_chile'
) \gexec

\connect sismos_chile
\ir schema.sql

-- Comprobacion visible al finalizar.
SELECT
    current_database() AS database_name,
    current_user AS database_user,
    PostGIS_Version() AS postgis_version;

SELECT
    schemaname,
    tablename
FROM pg_tables
WHERE schemaname = 'seismic'
ORDER BY tablename;

SELECT
    schemaname,
    indexname
FROM pg_indexes
WHERE schemaname = 'seismic'
ORDER BY indexname;

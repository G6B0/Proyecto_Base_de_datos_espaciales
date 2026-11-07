<#
.SYNOPSIS
  Carga la cartografia del Censo 2024 del INE (zonas urbanas y manzanas con
  poblacion) en PostGIS y calcula que zonas urbanas y cuanta poblacion hay
  cerca de cada sismo.

.DESCRIPTION
  Version integrada al repositorio del script original del equipo.
  Documentacion completa: docs/INE_CENSO2024.md.

  Pasos:
    1. Extrae del zip oficial del INE (Cartografia_censo2024_Pais.zip, 758 MB)
       solo las dos capas que usa el modelo:
         Cartografia_censo2024_Pais_Limite_Urbano.parquet  (592 ciudades y pueblos)
         Cartografia_censo2024_Pais_Manzanas.parquet       (216.341 manzanas)
       Si ya existen con el mismo tamano, no las vuelve a extraer.
    2. Detecta QGIS (cualquier 3.x en Program Files u OSGeo4W) y usa su GDAL
       (ogr2ogr) para leer GeoParquet. No modifica QGIS.
    3. Importa cada capa al esquema temporal ine_staging, reproyectando de
       SIRGAS 2000 (EPSG:4674) a WGS 84 (EPSG:4326) y conservando solo las
       columnas que usa el modelo.
    4. Ejecuta db/load_census.sql: valida, pasa los datos a
       seismic.urban_area y seismic.census_block y borra ine_staging.
    5. Ejecuta db/assign_urban_exposure.sql: zonas urbanas cercanas y
       poblacion expuesta de cada sismo.

  Es repetible: volver a ejecutarlo reemplaza los datos sin duplicarlos.

.EXAMPLE
  # Carga completa (zip en data\raw\ine\)
  PowerShell -ExecutionPolicy Bypass -File .\scripts\load_ine_manzanas_postgis.ps1

.EXAMPLE
  # Prueba rapida: solo 1.000 registros por capa en ine_staging, sin tocar el modelo
  PowerShell -ExecutionPolicy Bypass -File .\scripts\load_ine_manzanas_postgis.ps1 -Limit 1000

.EXAMPLE
  # Parquet ya descomprimidos en otra carpeta
  PowerShell -ExecutionPolicy Bypass -File .\scripts\load_ine_manzanas_postgis.ps1 -ParquetDir "D:\datos\censo2024"
#>
[CmdletBinding()]
param(
    [string]$ZipPath,                    # Zip oficial del INE (por defecto data\raw\ine\Cartografia_censo2024_Pais.zip)
    [string]$ParquetDir,                 # Carpeta con los .parquet ya extraidos (se salta el zip)
    [string]$QgisRoot,                   # Opcional: carpeta de QGIS (si no, se detecta)
    [string]$PgBin = 'C:\Program Files\PostgreSQL\18\bin',
    [int]$Limit = 0,                     # >0 = solo N registros por capa en ine_staging (prueba)
    [switch]$StagingOnly,                # Deja los datos en ine_staging sin pasarlos al modelo
    [switch]$SkipAssignment,             # Carga el modelo pero no recalcula la exposicion de sismos
    [switch]$CheckGeometry               # Cuenta geometrias invalidas en ine_staging (tarda)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Schema = 'ine_staging'
$loadSql = Join-Path $RepoRoot 'db\load_census.sql'
$assignSql = Join-Path $RepoRoot 'db\assign_urban_exposure.sql'

# Capa del INE -> tabla de staging y columnas que se importan (el resto de
# las 189 variables del censo queda en el parquet original).
$jobs = @(
    @{
        File    = 'Cartografia_censo2024_Pais_Limite_Urbano.parquet'
        Table   = 'limite_urbano'
        Columns = 'CUT,AREA_C,LOCALIDAD,ENTIDAD,CATEGORIA,ID_ENTIDAD,CONURBACION,' +
                  'n_per,n_edad_0_5,n_edad_60_mas,n_discapacidad,n_hog,n_vp,' +
                  'n_mat_paredes_artesanal,n_mat_paredes_precarios'
    },
    @{
        File    = 'Cartografia_censo2024_Pais_Manzanas.parquet'
        Table   = 'manzanas'
        Columns = 'CUT,AREA_C,TIPO_MZ,MANZENT,ID_ENTIDAD,MZ_BASE_CENSO,' +
                  'n_per,n_edad_60_mas,n_vp,n_mat_paredes_artesanal'
    }
)

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

# ---------------------------------------------------------------- .env
function Read-DotEnv([string]$Path) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $key = $t.Substring(0, $i).Trim()
        $val = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        $result[$key] = $val
    }
    return $result
}

# ---------------------------------------------------------------- QGIS
function Find-QgisRoot {
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $found = @()
    foreach ($b in $bases) {
        $dirs = Get-ChildItem -LiteralPath $b -Directory -Filter 'QGIS*' -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'bin\ogr2ogr.exe')) {
                $v = [version]'0.0.0'
                if ($d.Name -match '(\d+\.\d+\.\d+)') { $v = [version]$Matches[1] }
                $found += [pscustomobject]@{ Path = $d.FullName; Version = $v }
            }
        }
    }
    if (Test-Path -LiteralPath 'C:\OSGeo4W\bin\ogr2ogr.exe') {
        $found += [pscustomobject]@{ Path = 'C:\OSGeo4W'; Version = [version]'0.0.0' }
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object Version -Descending | Select-Object -First 1).Path
}

function Import-QgisEnvironment([string]$Root) {
    $envBat = Join-Path $Root 'bin\o4w_env.bat'
    if (Test-Path -LiteralPath $envBat) {
        # Ejecuta o4w_env.bat en cmd y copia las variables resultantes a este proceso.
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("qgis_env_{0}.cmd" -f $PID)
        Set-Content -LiteralPath $tmp -Encoding ASCII -Value @(
            '@echo off',
            ('call "{0}" >nul 2>&1' -f $envBat),
            'set'
        )
        try {
            $lines = & cmd.exe /c $tmp
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
        foreach ($l in $lines) {
            if ($l -match '^([^=]+)=(.*)$') {
                [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
            }
        }
    } else {
        # Sin o4w_env.bat: configuracion minima para que GDAL encuentre sus datos.
        $env:PATH = "{0};{1}" -f (Join-Path $Root 'bin'), $env:PATH
        $gdalData = Join-Path $Root 'share\gdal'
        $projLib  = Join-Path $Root 'share\proj'
        if (Test-Path -LiteralPath $gdalData) { $env:GDAL_DATA = $gdalData }
        if (Test-Path -LiteralPath $projLib)  { $env:PROJ_LIB = $projLib; $env:PROJ_DATA = $projLib }
    }
}

# ---------------------------------------------------------------- PostgreSQL
function Invoke-Psql([string]$Sql) {
    & $script:Psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p $script:DbPort -U $script:DbUser -d $script:DbName -c $Sql
    if ($LASTEXITCODE -ne 0) { throw "psql fallo con codigo $LASTEXITCODE." }
}

function Invoke-PsqlFile([string]$Path) {
    & $script:Psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p $script:DbPort -U $script:DbUser -d $script:DbName -f $Path
    if ($LASTEXITCODE -ne 0) { throw "Fallo la ejecucion de $Path; la transaccion fue revertida." }
}

# ================================================================ INICIO
Write-Step 'Buscando los archivos .parquet'
if (-not $ParquetDir) {
    if (-not $ZipPath) { $ZipPath = Join-Path $RepoRoot 'data\raw\ine\Cartografia_censo2024_Pais.zip' }
    $ZipPath = [IO.Path]::GetFullPath($ZipPath)
    if (-not (Test-Path -LiteralPath $ZipPath)) {
        throw "No encontre el zip del INE: $ZipPath. Descargalo (docs/INE_CENSO2024.md, paso 1) o usa -ParquetDir."
    }
    $ParquetDir = Join-Path (Split-Path -Parent $ZipPath) 'Cartografia_censo2024_Pais'
    New-Item -ItemType Directory -Force -Path $ParquetDir | Out-Null

    # Extraccion selectiva: solo las dos capas (el zip trae 11 archivos).
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($j in $jobs) {
            $entry = $zip.GetEntry($j.File)
            if (-not $entry) { throw "El zip no contiene $($j.File)" }
            $target = Join-Path $ParquetDir $j.File
            if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -eq $entry.Length)) {
                continue
            }
            Write-Host "Extrayendo $($j.File)"
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $zip.Dispose()
    }
}
if (-not (Test-Path -LiteralPath $ParquetDir)) { throw "No existe la carpeta $ParquetDir" }
foreach ($j in $jobs) {
    $j.Path = Join-Path $ParquetDir $j.File
    if (-not (Test-Path -LiteralPath $j.Path)) { throw "Falta el archivo: $($j.Path)" }
}
Write-Host "Carpeta: $ParquetDir"

Write-Step 'Buscando QGIS (GDAL)'
if (-not $QgisRoot) { $QgisRoot = $env:QGIS_ROOT }
if (-not $QgisRoot) { $QgisRoot = Find-QgisRoot }
if (-not $QgisRoot -or -not (Test-Path -LiteralPath (Join-Path $QgisRoot 'bin\ogr2ogr.exe'))) {
    throw 'No encontre QGIS. Indica la ruta con -QgisRoot "C:\Program Files\QGIS 3.44.13".'
}
Write-Host "QGIS: $QgisRoot"
Import-QgisEnvironment $QgisRoot
$ogr2ogr = Join-Path $QgisRoot 'bin\ogr2ogr.exe'
$ogrinfo = Join-Path $QgisRoot 'bin\ogrinfo.exe'

$parquetSupport = & $ogrinfo --formats | Select-String -Pattern 'Parquet'
if (-not $parquetSupport) {
    throw 'Esta instalacion de GDAL no soporta Parquet. Usa QGIS 3.44 o superior.'
}
Write-Host 'GDAL con soporte Parquet: OK'

Write-Step 'Preparando conexion a PostgreSQL'
$envFile = Read-DotEnv (Join-Path $RepoRoot '.env')
foreach ($key in 'POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_PORT') {
    if (-not $envFile.ContainsKey($key)) { throw "Falta $key en .env" }
}
$script:DbName = $envFile['POSTGRES_DB']
$script:DbUser = $envFile['POSTGRES_USER']
$script:DbPort = $envFile['POSTGRES_PORT']
$script:Psql = Join-Path $PgBin 'psql.exe'
$pgIsReady = Join-Path $PgBin 'pg_isready.exe'
foreach ($p in $script:Psql, $pgIsReady) {
    if (-not (Test-Path -LiteralPath $p)) { throw "No se encontro $p (usa -PgBin si PostgreSQL esta en otra carpeta)." }
}
foreach ($p in $loadSql, $assignSql) {
    if (-not (Test-Path -LiteralPath $p)) { throw "No se encontro $p" }
}

& $pgIsReady -h 127.0.0.1 -p $script:DbPort *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'La base no esta activa. Ejecuta primero scripts\start_local_postgis.ps1.'
}
Write-Host "Destino: $($script:DbUser)@127.0.0.1:$($script:DbPort)/$($script:DbName)"

$previousPassword = $env:PGPASSWORD
$previousClientEncoding = $env:PGCLIENTENCODING
try {
    $env:PGPASSWORD = $envFile['POSTGRES_PASSWORD']
    $env:PGCLIENTENCODING = 'UTF8'

    Write-Step "Creando esquema $Schema"
    Invoke-Psql "SET client_min_messages TO warning; DROP SCHEMA IF EXISTS $Schema CASCADE; CREATE SCHEMA $Schema;"

    $pgConn = "PG:host=127.0.0.1 port=$($script:DbPort) dbname=$($script:DbName) user=$($script:DbUser)"

    foreach ($j in $jobs) {
        $target = "$Schema.$($j.Table)"
        Write-Step "Importando $($j.File) -> $target"
        if ($Limit -gt 0) { Write-Host "MODO PRUEBA: solo $Limit registros." -ForegroundColor Yellow }

        $ogrArgs = @(
            '--config', 'PG_USE_COPY', 'YES',
            '-f', 'PostgreSQL', $pgConn, $j.Path,
            '-nln', $target,
            '-select', $j.Columns,
            '-t_srs', 'EPSG:4326',
            '-nlt', 'PROMOTE_TO_MULTI',
            '-lco', 'GEOMETRY_NAME=geom',
            '-lco', 'FID=gid',
            '-lco', 'SPATIAL_INDEX=NONE',
            '-gt', '20000',
            '-overwrite', '-progress'
        )
        if ($Limit -gt 0) { $ogrArgs += @('-limit', $Limit) }

        & $ogr2ogr @ogrArgs
        if ($LASTEXITCODE -ne 0) { throw "ogr2ogr fallo con codigo $LASTEXITCODE al importar $($j.File)." }
    }

    Write-Step 'Verificacion de ine_staging'
    Invoke-Psql "SELECT 'limite_urbano' AS tabla, count(*) AS filas, sum(n_per)::bigint AS personas FROM $Schema.limite_urbano UNION ALL SELECT 'manzanas', count(*), sum(n_per)::bigint FROM $Schema.manzanas;"
    if ($CheckGeometry) {
        Write-Step 'Revisando geometrias invalidas (puede tardar)'
        Invoke-Psql "SELECT count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS geometrias_invalidas FROM $Schema.manzanas;"
    }

    if ($Limit -gt 0 -or $StagingOnly) {
        Write-Host "`nDatos en $Schema; el modelo no se modifico." -ForegroundColor Yellow
        if ($Limit -gt 0) { Write-Host 'Para cargar todo, ejecuta de nuevo sin -Limit.' -ForegroundColor Yellow }
        return
    }

    Write-Step 'Pasando zonas urbanas y manzanas al modelo (db/load_census.sql)'
    Invoke-PsqlFile $loadSql

    if (-not $SkipAssignment) {
        Write-Step 'Zonas urbanas y poblacion cerca de cada sismo (db/assign_urban_exposure.sql)'
        Invoke-PsqlFile $assignSql
    }
} finally {
    $env:PGPASSWORD = $previousPassword
    $env:PGCLIENTENCODING = $previousClientEncoding
}

Write-Host "`nListo. Cartografia del Censo 2024 cargada en seismic.urban_area y seismic.census_block." -ForegroundColor Green

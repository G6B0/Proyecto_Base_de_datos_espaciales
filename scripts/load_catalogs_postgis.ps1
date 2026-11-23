# Carga los catalogos CSN y USGS en la base.
#   -CsnCsv  : CSV del CSN (por defecto data\processed\csn\csn_earthquake_catalog.csv).
#   -UsgsCsv : uno o varios CSV de USGS. Por defecto TODOS los
#              data\processed\usgs\usgs_earthquakes_chile*.csv (la muestra
#              reciente M>=2,5 y el catalogo completo M>=4 desde 1900). Si un
#              sismo esta en varios, se conserva su version mas nueva.
param(
    [string]$CsnCsv,
    [string[]]$UsgsCsv
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot '.env'
$sqlPath = Join-Path $projectRoot 'db\load_catalogs.sql'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$pgIsReady = 'C:\Program Files\PostgreSQL\18\bin\pg_isready.exe'

function Get-ProjectEnvValue {
    param([Parameter(Mandatory)][string]$Name)

    $prefix = "$Name="
    $line = Get-Content -LiteralPath $envPath |
        Where-Object { $_.StartsWith($prefix) } |
        Select-Object -First 1
    if (-not $line) {
        throw "Falta $Name en $envPath"
    }
    return $line.Substring($prefix.Length)
}

if (-not (Test-Path -LiteralPath $psql)) {
    throw "No se encontro $psql"
}
if (-not (Test-Path -LiteralPath $sqlPath)) {
    throw "No se encontro $sqlPath"
}

if (-not $CsnCsv) {
    $CsnCsv = Join-Path $projectRoot 'data\processed\csn\csn_earthquake_catalog.csv'
}
if (-not $UsgsCsv) {
    $UsgsCsv = @(Get-ChildItem `
        -Path (Join-Path $projectRoot 'data\processed\usgs') `
        -Filter 'usgs_earthquakes_chile*.csv' `
        -File `
        -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { $_.FullName })
    if ($UsgsCsv.Count -eq 0) {
        throw 'No se encontro un CSV procesado de USGS. Ejecuta primero el descargador.'
    }
}

$CsnCsv = [System.IO.Path]::GetFullPath($CsnCsv)
if (-not (Test-Path -LiteralPath $CsnCsv)) {
    throw "No se encontro el CSV del CSN: $CsnCsv"
}

# Una linea \copy por CSV de USGS. La lista de columnas sale del encabezado:
# asi los CSV anteriores a la entrega 3 (sin mmi, cdi, alert, product_types
# ni detail_url) se cargan igual, con esas columnas en NULL.
$usgsCopyLines = @()
$usgsFiles = @()
foreach ($path in $UsgsCsv) {
    $fullPath = [System.IO.Path]::GetFullPath($path)
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "No se encontro el CSV de USGS: $fullPath"
    }
    $header = (Get-Content -LiteralPath $fullPath -TotalCount 1 -Encoding UTF8).TrimStart([char]0xFEFF)
    $columns = $header.Split(',') | ForEach-Object { $_.Trim() }
    foreach ($column in $columns) {
        if ($column -notmatch '^[a-z_]+$') {
            throw "Columna inesperada '$column' en $fullPath"
        }
    }
    $escapedPath = $fullPath.Replace('\', '/').Replace("'", "''")
    $usgsCopyLines += "\copy import_usgs ($($columns -join ', ')) FROM '$escapedPath' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')"
    $usgsFiles += $escapedPath
    Write-Host "USGS: $fullPath"
}

$databaseName = Get-ProjectEnvValue -Name 'POSTGRES_DB'
$databaseUser = Get-ProjectEnvValue -Name 'POSTGRES_USER'
$databasePassword = Get-ProjectEnvValue -Name 'POSTGRES_PASSWORD'
$databasePort = Get-ProjectEnvValue -Name 'POSTGRES_PORT'

& $pgIsReady -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'La base no esta activa. Ejecuta primero scripts\start_local_postgis.ps1.'
}

$previousPassword = $env:PGPASSWORD
$temporarySql = [System.IO.Path]::GetTempFileName()
Push-Location $projectRoot
try {
    $env:PGPASSWORD = $databasePassword
    $sql = Get-Content -LiteralPath $sqlPath -Raw
    $escapedCsnPath = $CsnCsv.Replace('\', '/').Replace("'", "''")
    $sql = $sql.Replace('__CSN_CSV__', $escapedCsnPath)
    $sql = $sql.Replace('__USGS_COPY__', ($usgsCopyLines -join "`n"))
    $sql = $sql.Replace('__USGS_CSV__', ($usgsFiles -join '; '))
    [System.IO.File]::WriteAllText(
        $temporarySql,
        $sql,
        [System.Text.UTF8Encoding]::new($false)
    )
    & $psql `
        -h 127.0.0.1 `
        -p $databasePort `
        -U $databaseUser `
        -d $databaseName `
        -v ON_ERROR_STOP=1 `
        -f $temporarySql
    if ($LASTEXITCODE -ne 0) {
        throw 'La carga de catalogos fallo y fue revertida.'
    }

    # Mw homogeneo para comparar escalas distintas (docs/MAGNITUDES.md).
    Write-Host 'Calculando Mw homogeneo (db/homogenize_magnitudes.sql)'
    & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
        -v ON_ERROR_STOP=1 -f (Join-Path $projectRoot 'db\homogenize_magnitudes.sql')
    if ($LASTEXITCODE -ne 0) {
        throw 'El calculo de Mw homogeneo fallo; los eventos cargados se conservan.'
    }

    # Todas las magnitudes publicadas de cada evento (relacion 1:N).
    Write-Host 'Registrando magnitudes por evento (db/load_magnitude_estimates.sql)'
    & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
        -v ON_ERROR_STOP=1 -f (Join-Path $projectRoot 'db\load_magnitude_estimates.sql')
    if ($LASTEXITCODE -ne 0) {
        throw 'El registro de magnitudes por evento fallo; los eventos cargados se conservan.'
    }

    # Emparejamiento CSN-USGS: que registros son el mismo sismo (segundos).
    Write-Host 'Emparejando CSN y USGS (db/match_events.sql)'
    & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
        -v ON_ERROR_STOP=1 -f (Join-Path $projectRoot 'db\match_events.sql')
    if ($LASTEXITCODE -ne 0) {
        throw 'El emparejamiento CSN-USGS fallo; los eventos cargados se conservan.'
    }

    # Si la DPA ya esta cargada, se recalcula la comuna de cada evento para
    # incluir los sismos nuevos o con ubicacion revisada.
    $communeParts = & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
        -Atqc 'SELECT count(*) FROM seismic.administrative_area_part'
    if ($LASTEXITCODE -eq 0 -and [int]$communeParts -gt 0) {
        Write-Host 'Asignando eventos a comunas (db/assign_event_areas.sql)'
        & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
            -v ON_ERROR_STOP=1 -f (Join-Path $projectRoot 'db\assign_event_areas.sql')
        if ($LASTEXITCODE -ne 0) {
            throw 'La asignacion de comunas fallo; los eventos cargados se conservan.'
        }
    }
    else {
        Write-Host 'DPA no cargada: se omite la asignacion de comunas (scripts\load_dpa_postgis.ps1).'
    }

    # Si el Censo 2024 ya esta cargado, se calculan las zonas urbanas y la
    # poblacion cercanas a los eventos nuevos (modo incremental, segundos;
    # docs/INE_CENSO2024.md). El recalculo completo lo hace el cargador del censo.
    $urbanAreas = & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
        -Atqc 'SELECT count(*) FROM seismic.urban_area_part'
    if ($LASTEXITCODE -eq 0 -and [int]$urbanAreas -gt 0) {
        Write-Host 'Zonas urbanas y poblacion cerca de los eventos nuevos (db/assign_urban_exposure.sql)'
        & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
            -v ON_ERROR_STOP=1 -v incremental=1 -f (Join-Path $projectRoot 'db\assign_urban_exposure.sql')
        if ($LASTEXITCODE -ne 0) {
            throw 'El calculo de exposicion urbana fallo; los eventos cargados se conservan.'
        }
    }
    else {
        Write-Host 'Censo 2024 no cargado: se omite la exposicion urbana (scripts\load_ine_manzanas_postgis.ps1).'
    }
}
finally {
    Pop-Location
    $env:PGPASSWORD = $previousPassword
    if (Test-Path -LiteralPath $temporarySql) {
        Remove-Item -LiteralPath $temporarySql -Force
    }
}

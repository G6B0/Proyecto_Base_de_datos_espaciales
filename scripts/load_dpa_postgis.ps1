<#
Carga la Division Politico Administrativa (DPA) 2023 en PostGIS y asigna
cada sismo a una comuna.

Pasos:
  1. Extrae del zip oficial solo los shapefiles de regiones, provincias y
     comunas (el zip trae ademas ~85 MB de documentacion).
  2. Importa cada shapefile con shp2pgsql al esquema temporal dpa_staging,
     conservando su SRID original 5360 (SIRGAS-Chile 2002).
  3. Ejecuta db/load_dpa.sql: reproyecta a 4326, valida, hace UPSERT en
     seismic.administrative_area y genera los trozos de comuna.
  4. Ejecuta db/assign_event_areas.sql: asigna cada evento a una comuna.

Uso:
  PowerShell -ExecutionPolicy Bypass -File .\scripts\load_dpa_postgis.ps1
  PowerShell -ExecutionPolicy Bypass -File .\scripts\load_dpa_postgis.ps1 -ZipPath .\otra\ruta\dpa_2023.zip
  PowerShell -ExecutionPolicy Bypass -File .\scripts\load_dpa_postgis.ps1 -SkipAssignment
#>
param(
    [string]$ZipPath,
    [switch]$SkipAssignment
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot '.env'
$postgresBin = 'C:\Program Files\PostgreSQL\18\bin'
$psql = Join-Path $postgresBin 'psql.exe'
$pgIsReady = Join-Path $postgresBin 'pg_isready.exe'
$shp2pgsql = Join-Path $postgresBin 'shp2pgsql.exe'
$loadSql = Join-Path $projectRoot 'db\load_dpa.sql'
$assignSql = Join-Path $projectRoot 'db\assign_event_areas.sql'

# Capa del zip -> tabla de staging.
$layers = [ordered]@{
    'REGIONES/REGIONES_v1'     = 'dpa_staging.regiones'
    'PROVINCIAS/PROVINCIAS_v1' = 'dpa_staging.provincias'
    'COMUNAS/COMUNAS_v1'       = 'dpa_staging.comunas'
}
$shapefileExtensions = '.shp', '.shx', '.dbf', '.prj', '.cpg'

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

function Invoke-ProjectSqlFile {
    param([Parameter(Mandatory)][string]$Path)

    & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
        -v ON_ERROR_STOP=1 -f $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Fallo la ejecucion de $Path; la transaccion fue revertida."
    }
}

foreach ($path in $psql, $pgIsReady, $shp2pgsql, $loadSql, $assignSql, $envPath) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "No se encontro $path"
    }
}

if (-not $ZipPath) {
    $ZipPath = Join-Path $projectRoot 'data\raw\chile_boundaries\dpa_2023.zip'
}
$ZipPath = [System.IO.Path]::GetFullPath($ZipPath)
if (-not (Test-Path -LiteralPath $ZipPath)) {
    throw "No se encontro el zip de la DPA: $ZipPath"
}
$extractRoot = Join-Path (Split-Path -Parent $ZipPath) 'dpa_2023'

$databaseName = Get-ProjectEnvValue -Name 'POSTGRES_DB'
$databaseUser = Get-ProjectEnvValue -Name 'POSTGRES_USER'
$databasePassword = Get-ProjectEnvValue -Name 'POSTGRES_PASSWORD'
$databasePort = Get-ProjectEnvValue -Name 'POSTGRES_PORT'

& $pgIsReady -h 127.0.0.1 -p $databasePort *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'La base no esta activa. Ejecuta primero scripts\start_local_postgis.ps1.'
}

# 1. Extraccion selectiva del zip.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    foreach ($layer in $layers.Keys) {
        foreach ($extension in $shapefileExtensions) {
            $entryName = "$layer$extension"
            $entry = $zip.GetEntry($entryName)
            if (-not $entry) {
                throw "El zip no contiene $entryName"
            }
            $target = Join-Path $extractRoot ($entryName.Replace('/', '\'))
            if ((Test-Path -LiteralPath $target) -and
                ((Get-Item -LiteralPath $target).Length -eq $entry.Length)) {
                continue
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Write-Host "Extrayendo $entryName"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    }
}
finally {
    $zip.Dispose()
}

$previousPassword = $env:PGPASSWORD
$previousClientEncoding = $env:PGCLIENTENCODING
$temporaryFiles = New-Object System.Collections.Generic.List[string]
try {
    $env:PGPASSWORD = $databasePassword
    $env:PGCLIENTENCODING = 'UTF8'

    & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
        -v ON_ERROR_STOP=1 -qc 'DROP SCHEMA IF EXISTS dpa_staging CASCADE; CREATE SCHEMA dpa_staging;'
    if ($LASTEXITCODE -ne 0) {
        throw 'No se pudo preparar el esquema dpa_staging.'
    }

    # 2. shp2pgsql escribe un archivo SQL (formato COPY) que luego lee psql.
    # Se redirige con Start-Process para no pasar por el pipeline de
    # PowerShell, que puede recodificar los nombres con tildes o enie.
    foreach ($layer in $layers.Keys) {
        $shapefile = Join-Path $extractRoot ($layer.Replace('/', '\') + '.shp')
        $stagingTable = $layers[$layer]
        $sqlFile = [System.IO.Path]::GetTempFileName()
        $errorFile = [System.IO.Path]::GetTempFileName()
        $temporaryFiles.Add($sqlFile)
        $temporaryFiles.Add($errorFile)

        Write-Host "Convirtiendo $layer -> $stagingTable"
        $process = Start-Process -FilePath $shp2pgsql `
            -ArgumentList @('-s', '5360', '-g', 'geom', '-W', 'UTF-8', '-D', '-c', "`"$shapefile`"", $stagingTable) `
            -RedirectStandardOutput $sqlFile `
            -RedirectStandardError $errorFile `
            -NoNewWindow -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "shp2pgsql fallo con $layer`: $(Get-Content -LiteralPath $errorFile -Raw)"
        }

        Write-Host "Importando $stagingTable"
        & $psql -h 127.0.0.1 -p $databasePort -U $databaseUser -d $databaseName `
            -v ON_ERROR_STOP=1 -q -f $sqlFile
        if ($LASTEXITCODE -ne 0) {
            throw "No se pudo importar $stagingTable."
        }
    }

    # 3. Paso al modelo.
    Write-Host 'Cargando regiones, provincias y comunas en seismic.administrative_area'
    Invoke-ProjectSqlFile -Path $loadSql

    # 4. Asignacion de eventos.
    if (-not $SkipAssignment) {
        Write-Host 'Asignando cada evento a una comuna'
        Invoke-ProjectSqlFile -Path $assignSql
    }
}
finally {
    $env:PGPASSWORD = $previousPassword
    $env:PGCLIENTENCODING = $previousClientEncoding
    foreach ($file in $temporaryFiles) {
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force
        }
    }
}

Write-Host 'DPA 2023 cargada.'

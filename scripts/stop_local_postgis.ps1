$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$postgresBin = 'C:\Program Files\PostgreSQL\18\bin'
$clusterRoot = Join-Path $env:LOCALAPPDATA 'SismosChilePostgres'
$dataDirectory = Join-Path $clusterRoot 'data'

if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION'))) {
    Write-Host 'El cluster PostgreSQL aislado todavia no existe.'
    exit 0
}

& (Join-Path $postgresBin 'pg_ctl.exe') -D $dataDirectory stop -m fast
if ($LASTEXITCODE -ne 0) {
    throw 'No se pudo detener el cluster PostgreSQL aislado.'
}

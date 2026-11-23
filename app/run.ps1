# Levanta la interfaz "Sismos Chile · Observatorio" en http://127.0.0.1:8000
#
#   PowerShell -ExecutionPolicy Bypass -File .\app\run.ps1
#
# La primera vez crea el entorno de Python (app\.venv) e instala las
# dependencias. Requiere la base local encendida
# (scripts\start_local_postgis.ps1).

param([int]$Port = 8000, [switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$venvPython = Join-Path $projectRoot 'app\.venv\Scripts\python.exe'

if (-not (Test-Path -LiteralPath $venvPython)) {
    Write-Host 'Creando el entorno de Python (app\.venv)...'
    & py -3 -m venv (Join-Path $projectRoot 'app\.venv')
    & $venvPython -m pip install --disable-pip-version-check -q -r (Join-Path $projectRoot 'app\requirements.txt')
}

$pgIsReady = 'C:\Program Files\PostgreSQL\18\bin\pg_isready.exe'
& $pgIsReady -h 127.0.0.1 -p 5433 *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'La base no esta activa. Ejecuta primero scripts\start_local_postgis.ps1.'
}

if (-not $NoBrowser) {
    Start-Job -ScriptBlock { param($p) Start-Sleep 2; Start-Process "http://127.0.0.1:$p" } -ArgumentList $Port | Out-Null
}
Push-Location $projectRoot
try {
    & $venvPython -m uvicorn app.api.main:app --host 127.0.0.1 --port $Port
}
finally {
    Pop-Location
}

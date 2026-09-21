$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$postgresBin = 'C:\Program Files\PostgreSQL\18\bin'
$clusterRoot = Join-Path $env:LOCALAPPDATA 'SismosChilePostgres'
$dataDirectory = Join-Path $clusterRoot 'data'
$logDirectory = Join-Path $clusterRoot 'logs'
$logPath = Join-Path $logDirectory 'postgresql.log'
$envPath = Join-Path $projectRoot '.env'
$schemaPath = Join-Path $projectRoot 'db\schema.sql'

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

foreach ($executable in 'initdb.exe', 'pg_ctl.exe', 'pg_isready.exe', 'psql.exe', 'createdb.exe') {
    $path = Join-Path $postgresBin $executable
    if (-not (Test-Path -LiteralPath $path)) {
        throw "No se encontro $path"
    }
}
if (-not (Test-Path -LiteralPath $envPath)) {
    throw "No existe $envPath. Copia .env.example como .env y define una clave local."
}

$databaseName = Get-ProjectEnvValue -Name 'POSTGRES_DB'
$databaseUser = Get-ProjectEnvValue -Name 'POSTGRES_USER'
$databasePassword = Get-ProjectEnvValue -Name 'POSTGRES_PASSWORD'
$databasePort = Get-ProjectEnvValue -Name 'POSTGRES_PORT'

if ($databaseName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    throw 'POSTGRES_DB contiene caracteres no permitidos.'
}
if ($databaseUser -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    throw 'POSTGRES_USER contiene caracteres no permitidos.'
}
if ($databasePort -notmatch '^\d+$' -or [int]$databasePort -notin 1024..65535) {
    throw 'POSTGRES_PORT debe ser un puerto entre 1024 y 65535.'
}

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION'))) {
    if (Test-Path -LiteralPath $dataDirectory) {
        $resolvedClusterRoot = [System.IO.Path]::GetFullPath($clusterRoot).TrimEnd('\')
        $resolvedDataDirectory = [System.IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
        if (-not $resolvedDataDirectory.StartsWith("$resolvedClusterRoot\")) {
            throw "Ruta de datos fuera del directorio local esperado: $resolvedDataDirectory"
        }
        Write-Host "Eliminando inicializacion incompleta en $resolvedDataDirectory"
        Remove-Item -LiteralPath $resolvedDataDirectory -Recurse -Force
    }

    Write-Host "Inicializando cluster PostgreSQL aislado en $dataDirectory"
    $passwordFile = New-TemporaryFile
    try {
        [System.IO.File]::WriteAllText(
            $passwordFile.FullName,
            $databasePassword,
            [System.Text.UTF8Encoding]::new($false)
        )
        & (Join-Path $postgresBin 'initdb.exe') `
            -D $dataDirectory `
            -U $databaseUser `
            --encoding=UTF8 `
            --locale=C `
            --auth-local=scram-sha-256 `
            --auth-host=scram-sha-256 `
            --pwfile=$($passwordFile.FullName)
        if ($LASTEXITCODE -ne 0) {
            throw 'initdb no pudo crear el cluster.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $passwordFile.FullName) {
            Remove-Item -LiteralPath $passwordFile.FullName -Force
        }
    }
}

$readyArguments = @('-h', '127.0.0.1', '-p', $databasePort)
& (Join-Path $postgresBin 'pg_isready.exe') @readyArguments *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Iniciando PostgreSQL en 127.0.0.1:$databasePort"
    & (Join-Path $postgresBin 'pg_ctl.exe') `
        -D $dataDirectory `
        -l $logPath `
        -o "-p $databasePort -h 127.0.0.1" `
        start
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo iniciar PostgreSQL. Revisa $logPath"
    }
}

$isReady = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    & (Join-Path $postgresBin 'pg_isready.exe') @readyArguments *> $null
    if ($LASTEXITCODE -eq 0) {
        $isReady = $true
        break
    }
    Start-Sleep -Milliseconds 500
}
if (-not $isReady) {
    throw "PostgreSQL no quedo disponible en el puerto $databasePort."
}

$previousPassword = $env:PGPASSWORD
try {
    $env:PGPASSWORD = $databasePassword
    $psql = Join-Path $postgresBin 'psql.exe'
    $connectionArguments = @('-h', '127.0.0.1', '-p', $databasePort, '-U', $databaseUser)
    $exists = & $psql @connectionArguments -d postgres -Atqc `
        "SELECT 1 FROM pg_database WHERE datname = '$databaseName'"
    if ($LASTEXITCODE -ne 0) {
        throw 'No se pudo comprobar la base del proyecto.'
    }
    if ($exists -ne '1') {
        & (Join-Path $postgresBin 'createdb.exe') @connectionArguments $databaseName
        if ($LASTEXITCODE -ne 0) {
            throw "No se pudo crear la base $databaseName."
        }
    }

    & $psql @connectionArguments -d $databaseName -v ON_ERROR_STOP=1 -f $schemaPath
    if ($LASTEXITCODE -ne 0) {
        throw 'No se pudo aplicar db/schema.sql.'
    }

    & $psql @connectionArguments -d $databaseName -v ON_ERROR_STOP=1 -c @"
SELECT current_database(), current_user, PostGIS_Version();
SELECT tablename FROM pg_tables WHERE schemaname = 'seismic' ORDER BY tablename;
SELECT indexname FROM pg_indexes WHERE schemaname = 'seismic' ORDER BY indexname;
"@
    if ($LASTEXITCODE -ne 0) {
        throw 'La validacion final de la base fallo.'
    }
}
finally {
    $env:PGPASSWORD = $previousPassword
}

Write-Host "Base $databaseName lista en 127.0.0.1:$databasePort"

# Runspace bootstrap. Pode serves each request in its own runspace with no inherited
# module state, so every API route dot-sources this first to load the backend modules
# and attach to the already-initialized SQLite database. Idempotent and fast (our own
# .psm1 files only — heavy M365 modules are imported lazily inside the functions that
# actually connect, and only when a tenant/service is configured).

$ErrorActionPreference = 'Stop'
$modulesDir = $PSScriptRoot

foreach ($name in 'Logging', 'State', 'Connections', 'Mapping', 'Preflight', 'Provisioning', 'MigrationSetup', 'MailboxMove', 'FileMove') {
    $path = Join-Path $modulesDir "$name.psm1"
    if ((Test-Path $path) -and -not (Get-Module -Name $name)) {
        # -Global so exported functions land in the session-global table and remain
        # visible across modules (e.g. Preflight calling Mapping's Get-Mappings).
        Import-Module $path -Force -Global
    }
}

# Attach this runspace to the running database + log directory (set by server.ps1).
if ($env:MIG_DB_PATH -and (Get-Command Set-DatabasePath -ErrorAction SilentlyContinue)) {
    Set-DatabasePath -Path $env:MIG_DB_PATH | Out-Null
}
if ($env:MIG_LOG_DIR -and (Get-Command Initialize-Logging -ErrorAction SilentlyContinue)) {
    Initialize-Logging -Path $env:MIG_LOG_DIR | Out-Null
}

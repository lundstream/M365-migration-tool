# Runspace bootstrap. Pode serves each request in its own runspace with no inherited
# module state, so every API route dot-sources this first to load the backend modules
# and attach to the already-initialized SQLite database. Idempotent and fast (our own
# .psm1 files only — heavy M365 modules are imported lazily inside the functions that
# actually connect, and only when a tenant/service is configured).

$ErrorActionPreference = 'Stop'
$modulesDir = $PSScriptRoot

# --- Load the Graph identity stack FIRST, before any M365 service connects. ---------------
# Graph 2.36.1's Azure.Identity needs MSAL 4.82.1 (bundled with the Graph module), which is
# INCOMPATIBLE with EXO 3.10.0's newer MSAL 4.83.1 (the WithLogging(IIdentityLogger,Boolean)
# signature changed). .NET loads one MSAL per simple name in a context, so if EXO connects
# first its 4.83.1 wins and Graph cert auth dies with "Method not found". Importing the Graph
# Authentication MODULE first loads its 4.82.1 via PowerShell's per-module assembly isolation;
# EXO then loads its 4.83.1 alongside and BOTH work, regardless of later connect order.
# (A raw Assembly.LoadFrom does NOT work — it dumps into the default context and breaks EXO.)
try {
    if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
        Import-Module Microsoft.Graph.Authentication -RequiredVersion 2.36.1 -ErrorAction Stop
    }
}
catch { }

foreach ($name in 'Logging', 'State', 'Connections', 'Mapping', 'Preflight', 'Provisioning', 'MigrationSetup', 'MailboxMove', 'FileMove', 'Monitor', 'Reporting', 'Manifest', 'Groups', 'Permissions', 'ProjectReport', 'MailboxCopy', 'FileCopy') {
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

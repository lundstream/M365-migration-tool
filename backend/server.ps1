#requires -Version 7.0
<#
.SYNOPSIS
    Pode entrypoint for the M365 cross-tenant migration tool (localhost only).
.DESCRIPTION
    Initializes logging + SQLite, then starts a Pode HTTP server bound to localhost.
    Serves the built React frontend (frontend/dist) as static files and exposes the
    JSON API under /api. No mutations in Phase 0 — only a health endpoint.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$ModulesDir = Join-Path $PSScriptRoot 'modules'
$ApiDir     = Join-Path $PSScriptRoot 'api'
$DataDir    = Join-Path $RepoRoot 'data'
$LogDir     = Join-Path $DataDir 'logs'
$DistDir    = Join-Path $RepoRoot 'frontend/dist'

# --- Config: prefer real config.json, fall back to the committed example. ---
if (-not $ConfigPath) {
    $real = Join-Path $RepoRoot 'config/config.json'
    $ConfigPath = (Test-Path $real) ? $real : (Join-Path $RepoRoot 'config/config.example.json')
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$bindHost = $config.server.host
$port     = [int]$config.server.port

# --- Modules ---
Import-Module (Join-Path $ModulesDir 'Logging.psm1') -Force
Import-Module (Join-Path $ModulesDir 'State.psm1')   -Force

# --- Init logging + database (main runspace) ---
Initialize-Logging -Path $LogDir | Out-Null
$runId = New-RunId
$dbInfo = Initialize-Database -DataPath $DataDir
Write-JsonLog -RunId $runId -Level Information -Message 'Server starting' -Data @{
    db                = $dbInfo.DbPath
    migrationsApplied = $dbInfo.MigrationsApplied
    config            = $ConfigPath
}

Write-Host "M365 migration tool — starting Pode on http://${bindHost}:${port}" -ForegroundColor Cyan
Write-Host "  DB:       $($dbInfo.DbPath)"
Write-Host "  Config:   $ConfigPath"
Write-Host "  Frontend: $DistDir $(if (Test-Path $DistDir) { '(serving)' } else { '(not built — run npm run build in frontend/)' })"

# Pode runs the server scriptblock in its own runspace with closures disabled, so $using:
# and outer variables are unavailable inside it. Pass startup values via process env vars,
# which the in-process Pode runspaces can read.
$env:MIG_BIND_HOST   = $bindHost
$env:MIG_PORT        = $port
$env:MIG_API_DIR     = $ApiDir
$env:MIG_DIST_DIR    = $DistDir
$env:MIG_DB_PATH     = $dbInfo.DbPath
$env:MIG_RUN_ID      = $runId
$env:MIG_BACKEND_DIR = $PSScriptRoot
$env:MIG_LOG_DIR     = $LogDir
$env:MIG_CONFIG_PATH = $ConfigPath

Start-PodeServer -RootPath $PSScriptRoot -Threads 6 -ScriptBlock {

    Add-PodeEndpoint -Address $env:MIG_BIND_HOST -Port ([int]$env:MIG_PORT) -Protocol Http

    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging

    # Shared, read-only startup state for routes.
    Set-PodeState -Name 'app' -Value @{
        DbPath     = $env:MIG_DB_PATH
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        RunId      = $env:MIG_RUN_ID
    } | Out-Null

    # API routes (one file per resource).
    foreach ($routeFile in (Get-ChildItem -LiteralPath $env:MIG_API_DIR -Filter '*.ps1')) {
        . $routeFile.FullName
    }

    # Static frontend (SPA). Only mount if it has been built.
    if (Test-Path $env:MIG_DIST_DIR) {
        Add-PodeStaticRoute -Path '/' -Source $env:MIG_DIST_DIR -Defaults @('index.html')
    }
    else {
        Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
            Write-PodeJsonResponse -Value @{
                message = 'Frontend not built. Run: cd frontend; npm install; npm run build. API is live at /api/health.'
            }
        }
    }
}

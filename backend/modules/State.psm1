#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    SQLite-backed run/state persistence for the M365 migration tool.
.DESCRIPTION
    Wraps PSSQLite. Owns the database path, runs forward-only migrations from
    backend/migrations/*.sql, and exposes small helpers for runs and the audit trail.
    State is snapshotted to disk so long-running operations survive a crash/restart
    (BRIEF.md guardrail #3).
#>

$script:DbPath = $null

function Get-MigrationsPath {
    # backend/modules -> backend/migrations
    return (Join-Path (Split-Path $PSScriptRoot -Parent) 'migrations')
}

function Invoke-DbQuery {
    <#
    .SYNOPSIS
        Runs a query against the initialized database via PSSQLite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Query,
        [hashtable]$SqlParameters
    )
    if (-not $script:DbPath) {
        throw 'Database not initialized. Call Initialize-Database first.'
    }
    # Open a short-lived connection with a busy timeout. Copy workers now run in their OWN process
    # (Start-Job) while the API server polls the same app.db, so without a busy timeout a writer
    # that collides with the server's reads fails instantly ("database is locked") and the per-item
    # catch swallows it — silently losing counter updates. The timeout makes it wait for the lock.
    $conn = New-SQLiteConnection -DataSource $script:DbPath
    try {
        Invoke-SqliteQuery -SQLiteConnection $conn -Query 'PRAGMA busy_timeout=15000;' | Out-Null
        $params = @{ SQLiteConnection = $conn; Query = $Query }
        if ($SqlParameters) { $params.SqlParameters = $SqlParameters }
        return Invoke-SqliteQuery @params
    }
    finally { if ($conn) { $conn.Close(); $conn.Dispose() } }
}

function Invoke-DbMigration {
    <#
    .SYNOPSIS
        Applies any migration files not yet recorded in schema_version, in order.
    #>
    [CmdletBinding()]
    param()

    # Bootstrap the version table so we can read what's been applied.
    Invoke-DbQuery -Query @'
CREATE TABLE IF NOT EXISTS schema_version (
    version     INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    applied_utc TEXT    NOT NULL
);
'@ | Out-Null

    $appliedRows = Invoke-DbQuery -Query 'SELECT version FROM schema_version;'
    $applied = @{}
    foreach ($r in @($appliedRows)) { if ($null -ne $r) { $applied[[int]$r.version] = $true } }

    $migrationsPath = Get-MigrationsPath
    if (-not (Test-Path -LiteralPath $migrationsPath)) {
        throw "Migrations folder not found: $migrationsPath"
    }

    $files = Get-ChildItem -LiteralPath $migrationsPath -Filter '*.sql' | Sort-Object Name
    $newlyApplied = @()
    foreach ($f in $files) {
        if ($f.Name -notmatch '^(?<num>\d+)_(?<name>.+)\.sql$') {
            Write-Warning "Skipping migration with unexpected name: $($f.Name)"
            continue
        }
        $version = [int]$Matches['num']
        $name = $Matches['name']
        if ($applied.ContainsKey($version)) { continue }

        $sql = Get-Content -LiteralPath $f.FullName -Raw
        Invoke-DbQuery -Query $sql | Out-Null
        Invoke-DbQuery -Query 'INSERT INTO schema_version (version, name, applied_utc) VALUES (@v, @n, @t);' `
            -SqlParameters @{ v = $version; n = $name; t = [DateTime]::UtcNow.ToString('o') } | Out-Null
        $newlyApplied += "$version`_$name"
    }
    return $newlyApplied
}

function Initialize-Database {
    <#
    .SYNOPSIS
        Creates the data directory and database file, then runs migrations.
    .PARAMETER DataPath
        Directory for the SQLite file (default <repo>/data).
    .PARAMETER FileName
        Database file name (default app.db).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DataPath,
        [string]$FileName = 'app.db'
    )

    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        throw 'PSSQLite is not installed. Run scripts/Install-Requirements.ps1.'
    }
    Import-Module PSSQLite -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $DataPath)) {
        New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
    }
    $script:DbPath = Join-Path (Resolve-Path -LiteralPath $DataPath).Path $FileName

    # Touch the database (PSSQLite creates the file on first query).
    Invoke-DbQuery -Query 'PRAGMA journal_mode=WAL;' | Out-Null
    $applied = Invoke-DbMigration

    return [pscustomobject]@{
        DbPath          = $script:DbPath
        MigrationsApplied = $applied
    }
}

function Get-DatabasePath {
    [CmdletBinding()]
    param()
    return $script:DbPath
}

function Set-DatabasePath {
    <#
    .SYNOPSIS
        Points this runspace at an already-initialized database (no migrations run).
    .DESCRIPTION
        Pode serves each request in its own runspace, so module-scoped state does not
        carry over from server startup. Routes call this to attach to the existing DB
        created by Initialize-Database at boot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path
    )
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        throw 'PSSQLite is not installed. Run scripts/Install-Requirements.ps1.'
    }
    Import-Module PSSQLite -ErrorAction Stop
    $script:DbPath = $Path
    return $script:DbPath
}

function New-Run {
    <#
    .SYNOPSIS
        Records the start of a run and returns its row.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RunId,
        [Parameter(Mandatory)] [string]$Kind,
        [string]$Notes
    )
    Invoke-DbQuery -Query @'
INSERT INTO runs (run_id, kind, status, started_utc, notes)
VALUES (@id, @kind, 'started', @started, @notes);
'@ -SqlParameters @{
        id      = $RunId
        kind    = $Kind
        started = [DateTime]::UtcNow.ToString('o')
        notes   = $Notes
    } | Out-Null
    return Invoke-DbQuery -Query 'SELECT * FROM runs WHERE run_id = @id;' -SqlParameters @{ id = $RunId }
}

function Set-AppState {
    <#
    .SYNOPSIS
        Upserts a key/value into the cross-runspace app_state store.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, [string]$Value)
    Invoke-DbQuery -Query @'
INSERT INTO app_state (key, value, updated_utc) VALUES (@k, @v, @t)
ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_utc = excluded.updated_utc;
'@ -SqlParameters @{ k = $Key; v = $Value; t = [DateTime]::UtcNow.ToString('o') } | Out-Null
}

function Get-AppState {
    <#
    .SYNOPSIS
        Reads a key from app_state. Returns @{ value; updatedUtc } or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    $row = @(Invoke-DbQuery -Query 'SELECT value, updated_utc FROM app_state WHERE key = @k;' -SqlParameters @{ k = $Key }) | Select-Object -First 1
    if (-not $row) { return $null }
    return @{ value = $row.value; updatedUtc = $row.updated_utc }
}

function Add-AuditEntry {
    <#
    .SYNOPSIS
        Appends an immutable audit record for a mutating action.
    #>
    [CmdletBinding()]
    param(
        [string]$RunId,
        [string]$CorrelationId,
        [string]$Actor = $env:USERNAME,
        [Parameter(Mandatory)] [string]$Action,
        [string]$Target,
        [string]$Detail
    )
    Invoke-DbQuery -Query @'
INSERT INTO audit_log (run_id, correlation_id, actor, action, target, detail, created_utc)
VALUES (@run, @corr, @actor, @action, @target, @detail, @created);
'@ -SqlParameters @{
        run     = $RunId
        corr    = $CorrelationId
        actor   = $Actor
        action  = $Action
        target  = $Target
        detail  = $Detail
        created = [DateTime]::UtcNow.ToString('o')
    } | Out-Null
}

Export-ModuleMember -Function Initialize-Database, Invoke-DbQuery, Invoke-DbMigration, `
    Get-DatabasePath, Set-DatabasePath, New-Run, Add-AuditEntry, Set-AppState, Get-AppState

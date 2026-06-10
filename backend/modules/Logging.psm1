#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Structured JSONL + human-readable run logging for the M365 migration tool.
.DESCRIPTION
    One JSONL file and one .log file per run, written under the configured log root
    (default: <repo>/data/logs). Every structured line carries a run id and an optional
    correlation id so mutations can be traced end to end (see BRIEF.md section 6).
#>

$script:LogRoot = $null

function Initialize-Logging {
    <#
    .SYNOPSIS
        Sets (and creates) the directory that run logs are written to.
    .PARAMETER Path
        Directory for .jsonl / .log files. Created if missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $script:LogRoot = (Resolve-Path -LiteralPath $Path).Path
    return $script:LogRoot
}

function New-RunId {
    <#
    .SYNOPSIS
        Generates a sortable, unique run id: run-yyyyMMdd-HHmmss-<6 hex>.
    #>
    [CmdletBinding()]
    param()
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $suffix = ([guid]::NewGuid().ToString('N')).Substring(0, 6)
    return "run-$stamp-$suffix"
}

function New-CorrelationId {
    <#
    .SYNOPSIS
        Generates a correlation id for a single mutating operation.
    #>
    [CmdletBinding()]
    param()
    return [guid]::NewGuid().ToString()
}

function Write-JsonLog {
    <#
    .SYNOPSIS
        Appends one structured JSON object (single line) to the run's .jsonl file.
    .PARAMETER RunId
        The run this entry belongs to.
    .PARAMETER Message
        Human-readable message.
    .PARAMETER Level
        Severity: Debug | Information | Warning | Error.
    .PARAMETER CorrelationId
        Optional id tying this entry to a specific operation.
    .PARAMETER Data
        Optional hashtable of extra structured fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RunId,
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]$Level = 'Information',
        [string]$CorrelationId,
        [hashtable]$Data
    )

    if (-not $script:LogRoot) {
        throw 'Logging not initialized. Call Initialize-Logging first.'
    }

    $entry = [ordered]@{
        timestamp     = [DateTime]::UtcNow.ToString('o')
        level         = $Level
        runId         = $RunId
        correlationId = $CorrelationId
        message       = $Message
    }
    if ($Data) { $entry.data = $Data }

    $line = ($entry | ConvertTo-Json -Compress -Depth 8)
    $jsonlPath = Join-Path $script:LogRoot "$RunId.jsonl"
    Add-Content -LiteralPath $jsonlPath -Value $line -Encoding utf8

    # Human-readable companion line.
    $human = '{0} [{1,-11}] {2}{3}' -f `
        $entry.timestamp, $Level, $Message, ($(if ($CorrelationId) { " (corr=$CorrelationId)" } else { '' }))
    $logPath = Join-Path $script:LogRoot "$RunId.log"
    Add-Content -LiteralPath $logPath -Value $human -Encoding utf8

    return $entry
}

Export-ModuleMember -Function Initialize-Logging, New-RunId, New-CorrelationId, Write-JsonLog

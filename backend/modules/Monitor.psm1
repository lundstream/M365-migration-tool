#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unified monitoring across mailbox batches + OneDrive/SharePoint moves (Phase 7).
.DESCRIPTION
    Get-MonitorModel reads persisted state from SQLite and normalizes mailbox batches and
    file-move jobs into ONE progress model (per-batch/per-item progress, derived percent,
    naive ETA, and a throttling indicator). It is cheap — the UI polls it on an interval.

    Invoke-MonitorRefresh does the expensive live poll: it reconciles active mailbox batches
    (Get-MigrationBatch / Get-MigrationUser) and active file-move jobs
    (Get-SPOCrossTenant*ContentMoveState) with the cloud, then returns the refreshed model.

    GUARDRAIL #4: the EXO stat cmdlet shapes (Get-MigrationUser .PercentageComplete/.Status)
    are post-connect REST and not introspectable offline; refresh reuses the guarded
    Update-MailboxBatchStatus / Update-FileMoveState from Phases 5/6. SPO move-state shapes
    were verified offline.

    Depends on State.psm1, MailboxMove.psm1, FileMove.psm1 in the same runspace.
#>

function Get-DerivedPercent {
    param([string]$Status, $Percent)
    if ($null -ne $Percent -and "$Percent" -ne '') { return [int]$Percent }
    switch ($Status) {
        'completed'  { 100; break }
        'synced'     { 100; break }
        'completing' { 100; break }
        'success'    { 100; break }
        'inprogress' { 50; break }
        'scheduled'  { 0; break }
        'syncing'    { 0; break }
        'queued'     { 0; break }
        default      { 0 }
    }
}

function Get-EtaText {
    param([string]$StartUtc, [int]$Percent)
    if ($Percent -le 0 -or $Percent -ge 100 -or -not $StartUtc) { return $null }
    try {
        $start = [datetime]::Parse($StartUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $elapsed = ([DateTime]::UtcNow - $start).TotalSeconds
        if ($elapsed -le 0) { return $null }
        $remaining = $elapsed / $Percent * (100 - $Percent)
        $ts = [TimeSpan]::FromSeconds([Math]::Min($remaining, 60 * 60 * 24 * 30))
        if ($ts.TotalHours -ge 1) { return ('~{0}h {1}m' -f [int]$ts.TotalHours, $ts.Minutes) }
        if ($ts.TotalMinutes -ge 1) { return ('~{0}m' -f [int]$ts.TotalMinutes) }
        return '~<1m'
    }
    catch { return $null }
}

function Get-MonitorModel {
    <#
    .SYNOPSIS
        Normalized, cheap progress model read from persisted state.
    #>
    [CmdletBinding()] param()

    $done = 0; $inprogress = 0; $failed = 0; $total = 0

    # Mailbox batches.
    $batches = @()
    foreach ($b in (Get-MailboxBatches)) {
        $full = Get-MailboxBatch -BatchId $b.batchId
        $items = foreach ($it in $full.items) {
            $pct = Get-DerivedPercent -Status $it.status -Percent $it.percent
            $total++
            if ($it.status -in @('completed')) { $done++ }
            elseif ($it.status -eq 'failed') { $failed++ }
            else { $inprogress++ }
            [ordered]@{
                source = $it.sourceUpn; target = $it.targetUpn; status = $it.status
                percent = $pct; eta = (Get-EtaText -StartUtc $full.createdUtc -Percent $pct)
                exoStatus = $it.exoStatus
            }
        }
        $items = @($items)
        $batchPct = if ($items.Count -gt 0) { [int](($items | Measure-Object -Property percent -Average).Average) } else { 0 }
        $batches += [ordered]@{
            batchId = $full.batchId; name = $full.name; status = $full.status
            percent = $batchPct; itemCount = $full.itemCount; updatedUtc = $full.updatedUtc; items = $items
        }
    }

    # File moves (OneDrive + SharePoint).
    $fileMoves = foreach ($j in (Get-FileMoveJobs)) {
        $pct = Get-DerivedPercent -Status $j.status -Percent $null
        $total++
        if ($j.status -eq 'success') { $done++ }
        elseif ($j.status -in @('failed', 'stopped')) { $failed++ }
        else { $inprogress++ }
        [ordered]@{
            jobId = $j.jobId; kind = $j.type; source = $j.source; target = $j.target
            status = $j.status; percent = $pct; redirectStatus = $j.redirectStatus; updatedUtc = $j.updatedUtc
        }
    }

    # Throttling indicator.
    $throttle = @{ active = $false; lastUtc = $null }
    $ts = Get-AppState -Key 'lastThrottleUtc'
    if ($ts -and $ts.value) {
        $throttle.lastUtc = $ts.value
        try { $throttle.active = (([DateTime]::UtcNow - [datetime]::Parse($ts.value, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalSeconds -lt 120) } catch { }
    }

    return [ordered]@{
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        throttling   = $throttle
        summary      = [ordered]@{ total = $total; inProgress = $inprogress; done = $done; failed = $failed }
        mailboxBatches = @($batches)
        fileMoves    = @($fileMoves)
    }
}

function Invoke-MonitorRefresh {
    <#
    .SYNOPSIS
        Live poll: reconcile active mailbox batches + file moves with the cloud, then return
        the refreshed model. Sequential (bounded) and resume-safe.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Config)

    $activeBatch = @('syncing', 'synced', 'completing')
    foreach ($b in (Get-MailboxBatches)) {
        if ($b.status -in $activeBatch) {
            try { Update-MailboxBatchStatus -Config $Config -BatchId $b.batchId | Out-Null } catch { }
        }
    }
    $activeJob = @('scheduled', 'inprogress')
    foreach ($j in (Get-FileMoveJobs)) {
        if ($j.status -in $activeJob) {
            try { Update-FileMoveState -Config $Config -JobId $j.jobId | Out-Null } catch { }
        }
    }
    return Get-MonitorModel
}

Export-ModuleMember -Function Get-MonitorModel, Invoke-MonitorRefresh

#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Reporting, logging and audit (Phase 8). Reads SQLite + JSONL; exports CSV / HTML.
.DESCRIPTION
    Produces, from persisted state:
      - per-run summary (runs table),
      - per-user / per-site status (mappings vs provisioning vs mailbox/file moves),
      - failures with reasons and the failing cmdlet (DB errors + JSONL error lines),
      - a full audit trail of every mutating action (who / when / what + correlation ids),
      - a post-migration reconciliation report (intended mappings vs actual completed moves).
    Each report is a { title; columns; rows } shape so the UI and the CSV/HTML exporters
    share one representation.

    Depends on State.psm1 in the same runspace.
#>

function New-Report {
    param([string]$Title, [string[]]$Columns, $Rows)
    # @($null) yields a 1-element [null] array; filter so empty reports are truly empty.
    $clean = @($Rows | Where-Object { $null -ne $_ })
    return [ordered]@{ title = $Title; columns = $Columns; rows = $clean; generatedUtc = [DateTime]::UtcNow.ToString('o') }
}

function Get-RunsReport {
    [CmdletBinding()] param()
    $rows = Invoke-DbQuery -Query 'SELECT run_id, kind, status, started_utc, ended_utc, notes FROM runs ORDER BY started_utc DESC;'
    $out = @($rows) | ForEach-Object {
        [ordered]@{ RunId = $_.run_id; Kind = $_.kind; Status = $_.status; Started = $_.started_utc; Ended = $_.ended_utc; Notes = $_.notes }
    }
    return New-Report -Title 'Runs' -Columns @('RunId', 'Kind', 'Status', 'Started', 'Ended', 'Notes') -Rows $out
}

function Get-AuditReport {
    [CmdletBinding()] param([string]$RunId, [int]$Limit = 1000)
    $q = 'SELECT created_utc, actor, action, target, detail, correlation_id, run_id FROM audit_log'
    $p = @{}
    if ($RunId) { $q += ' WHERE run_id = @r'; $p.r = $RunId }
    $q += ' ORDER BY created_utc DESC LIMIT @lim;'; $p.lim = $Limit
    $rows = Invoke-DbQuery -Query $q -SqlParameters $p
    $out = @($rows) | ForEach-Object {
        [ordered]@{ When = $_.created_utc; Who = $_.actor; Action = $_.action; Target = $_.target; Detail = $_.detail; CorrelationId = $_.correlation_id; RunId = $_.run_id }
    }
    return New-Report -Title 'Audit trail' -Columns @('When', 'Who', 'Action', 'Target', 'Detail', 'CorrelationId', 'RunId') -Rows $out
}

function Get-StatusReport {
    [CmdletBinding()] param()
    # Intended set = mappings; overlay provisioning + mailbox move + onedrive move.
    $maps = @(Invoke-DbQuery -Query 'SELECT source_upn, target_upn, match_state, target_exists FROM mappings;')
    $prov = @{}; foreach ($r in @(Invoke-DbQuery -Query 'SELECT source_upn, status FROM provisioning_results;')) { $prov[$r.source_upn] = $r.status }
    $mbx = @{}; foreach ($r in @(Invoke-DbQuery -Query 'SELECT source_upn, status FROM mailbox_batch_items;')) { $mbx[$r.source_upn] = $r.status }
    $od = @{}; foreach ($r in @(Invoke-DbQuery -Query "SELECT source, status FROM file_move_jobs WHERE type='onedrive';")) { $od[$r.source] = $r.status }

    $out = foreach ($m in $maps) {
        [ordered]@{
            SourceUpn   = $m.source_upn
            TargetUpn   = $m.target_upn
            Mapping     = $m.match_state
            Provisioned = if ($prov.ContainsKey($m.source_upn)) { $prov[$m.source_upn] } elseif ([int]$m.target_exists -eq 1) { 'exists' } else { '—' }
            MailboxMove = if ($mbx.ContainsKey($m.source_upn)) { $mbx[$m.source_upn] } else { '—' }
            OneDriveMove = if ($od.ContainsKey($m.source_upn)) { $od[$m.source_upn] } else { '—' }
        }
    }
    return New-Report -Title 'Per-user status' -Columns @('SourceUpn', 'TargetUpn', 'Mapping', 'Provisioned', 'MailboxMove', 'OneDriveMove') -Rows $out
}

function Get-FailuresReport {
    [CmdletBinding()] param()
    $rows = [System.Collections.Generic.List[object]]::new()

    function Add-Fail($scope, $subject, $reason, $cmdlet) {
        $rows.Add([ordered]@{ Scope = $scope; Subject = $subject; Reason = $reason; FailingCmdlet = $cmdlet })
    }

    foreach ($r in @(Invoke-DbQuery -Query "SELECT source_upn, error FROM mailbox_batch_items WHERE status='failed' AND error IS NOT NULL;")) {
        Add-Fail 'mailbox' $r.source_upn $r.error (Get-CmdletFromText $r.error)
    }
    foreach ($r in @(Invoke-DbQuery -Query "SELECT source_upn, reason FROM provisioning_results WHERE status='failed';")) {
        Add-Fail 'provisioning' $r.source_upn $r.reason (Get-CmdletFromText $r.reason)
    }
    foreach ($r in @(Invoke-DbQuery -Query "SELECT scope, subject, reason FROM preflight_results WHERE status='BLOCK';")) {
        Add-Fail "preflight/$($r.scope)" $r.subject $r.reason $null
    }
    foreach ($r in @(Invoke-DbQuery -Query "SELECT type, source, move_state FROM file_move_jobs WHERE status='failed';")) {
        Add-Fail "filemove/$($r.type)" $r.source "Move state: $($r.move_state)" $null
    }

    # JSONL error lines (failing cmdlet often embedded in the message).
    if ($env:MIG_LOG_DIR -and (Test-Path $env:MIG_LOG_DIR)) {
        foreach ($f in (Get-ChildItem -LiteralPath $env:MIG_LOG_DIR -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
            foreach ($line in (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
                if ($line -notmatch '"level":"Error"') { continue }
                try {
                    $o = $line | ConvertFrom-Json
                    $err = if ($o.PSObject.Properties.Name -contains 'data' -and $o.data -and ($o.data.PSObject.Properties.Name -contains 'error')) { $o.data.error } else { $o.message }
                    Add-Fail "log/$($o.runId)" $o.message $err (Get-CmdletFromText "$($o.message) $err")
                }
                catch { }
            }
        }
    }
    return New-Report -Title 'Failures' -Columns @('Scope', 'Subject', 'Reason', 'FailingCmdlet') -Rows $rows
}

function Get-CmdletFromText {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '\b([A-Z][a-zA-Z]+-[A-Z][a-zA-Z]+)\b')
    return ($(if ($m.Success) { $m.Groups[1].Value } else { $null }))
}

function Get-ReconciliationReport {
    [CmdletBinding()] param()
    # Compare intended (matched mappings) vs actual completed moves.
    $maps = @(Invoke-DbQuery -Query "SELECT source_upn, target_upn FROM mappings WHERE match_state='matched' AND target_upn IS NOT NULL;")
    $mbx = @{}; foreach ($r in @(Invoke-DbQuery -Query 'SELECT source_upn, status FROM mailbox_batch_items;')) { $mbx[$r.source_upn] = $r.status }
    $od = @{}; foreach ($r in @(Invoke-DbQuery -Query "SELECT source, status FROM file_move_jobs WHERE type='onedrive';")) { $od[$r.source] = $r.status }
    $prov = @{}; foreach ($r in @(Invoke-DbQuery -Query 'SELECT source_upn, status FROM provisioning_results;')) { $prov[$r.source_upn] = $r.status }

    $out = foreach ($m in $maps) {
        $mb = if ($mbx.ContainsKey($m.source_upn)) { $mbx[$m.source_upn] } else { $null }
        $one = if ($od.ContainsKey($m.source_upn)) { $od[$m.source_upn] } else { $null }
        $pr = if ($prov.ContainsKey($m.source_upn)) { $prov[$m.source_upn] } else { $null }

        $states = @($mb, $one) | Where-Object { $_ }
        $status =
            if (($mb -eq 'failed') -or ($one -eq 'failed')) { 'failed' }
            elseif ($mb -eq 'completed' -and ($one -in @($null, 'success'))) { 'reconciled' }
            elseif ($states.Count -eq 0) { 'pending' }
            else { 'in-progress' }

        [ordered]@{
            SourceUpn = $m.source_upn; TargetUpn = $m.target_upn
            Provisioned = ($pr ?? '—'); MailboxMove = ($mb ?? 'none'); OneDriveMove = ($one ?? 'none')
            Reconciliation = $status
        }
    }
    $out = @($out)
    $summary = [ordered]@{
        intended    = $out.Count
        reconciled  = @($out | Where-Object { $_.Reconciliation -eq 'reconciled' }).Count
        inProgress  = @($out | Where-Object { $_.Reconciliation -eq 'in-progress' }).Count
        pending     = @($out | Where-Object { $_.Reconciliation -eq 'pending' }).Count
        failed      = @($out | Where-Object { $_.Reconciliation -eq 'failed' }).Count
    }
    $rep = New-Report -Title 'Post-migration reconciliation' -Columns @('SourceUpn', 'TargetUpn', 'Provisioned', 'MailboxMove', 'OneDriveMove', 'Reconciliation') -Rows $out
    $rep.summary = $summary
    return $rep
}

function Get-Report {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('runs', 'audit', 'status', 'failures', 'reconciliation')][string]$Name, [string]$RunId)
    switch ($Name) {
        'runs'           { Get-RunsReport }
        'audit'          { Get-AuditReport -RunId $RunId }
        'status'         { Get-StatusReport }
        'failures'       { Get-FailuresReport }
        'reconciliation' { Get-ReconciliationReport }
    }
}

# ---------------- Exporters ----------------

function ConvertTo-ReportCsv {
    [CmdletBinding()] param([Parameter(Mandatory)] $Report)
    $objs = $Report.rows | ForEach-Object {
        $o = [ordered]@{}
        foreach ($c in $Report.columns) { $o[$c] = $_[$c] }
        [pscustomobject]$o
    }
    if (-not $objs) { return ($Report.columns -join ',') }
    return (($objs | ConvertTo-Csv -NoTypeInformation) -join "`r`n")
}

function ConvertTo-ReportHtml {
    [CmdletBinding()] param([Parameter(Mandatory)] $Report)
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $head = ($Report.columns | ForEach-Object { "<th>$(& $enc $_)</th>" }) -join ''
    $body = ($Report.rows | ForEach-Object {
        $r = $_
        '<tr>' + (($Report.columns | ForEach-Object { "<td>$(& $enc $r[$_])</td>" }) -join '') + '</tr>'
    }) -join "`n"
    $summaryHtml = ''
    if ($Report.Contains('summary')) {
        $summaryHtml = '<div class="summary">' + (($Report.summary.GetEnumerator() | ForEach-Object { "<span><b>$($_.Value)</b> $($_.Key)</span>" }) -join ' &middot; ') + '</div>'
    }
    return @"
<!doctype html><html><head><meta charset="utf-8"><title>$(& $enc $Report.title)</title>
<style>
body{font-family:system-ui,Segoe UI,Roboto,sans-serif;margin:2rem;color:#1a1a1a}
h1{font-size:1.3rem} .meta{color:#555;margin-bottom:.5rem}
.summary{margin:.5rem 0 1rem} .summary span{margin-right:1rem}
table{border-collapse:collapse;width:100%;font-size:.85rem;margin-top:1rem}
th,td{border:1px solid #ddd;padding:.4rem .6rem;text-align:left;vertical-align:top}
th{background:#f5f5f5}
</style></head><body>
<h1>$(& $enc $Report.title)</h1>
<div class="meta">Generated $($Report.generatedUtc) &middot; $($Report.rows.Count) row(s)</div>
$summaryHtml
<table><thead><tr>$head</tr></thead><tbody>
$body
</tbody></table>
</body></html>
"@
}

Export-ModuleMember -Function Get-RunsReport, Get-AuditReport, Get-StatusReport, Get-FailuresReport, Get-ReconciliationReport, Get-Report, ConvertTo-ReportCsv, ConvertTo-ReportHtml

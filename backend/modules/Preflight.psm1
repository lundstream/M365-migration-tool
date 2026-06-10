#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Read-only preflight validation for cross-tenant moves (Phase 3).
.DESCRIPTION
    For the current mapping set, validates (NEVER mutating either tenant):
      - target MailUser objects exist for mapped targets,
      - the Cross Tenant User Data Migration add-on is available on the target,
      - no source mailbox is on hold (holds block cross-tenant moves),
      - the migration endpoint / organization relationship exists on the target,
      - the SPO cross-tenant relationship exists.
    Produces per-check PASS / WARN / BLOCK rows with reasons, persisted to SQLite, and
    rendered on-screen and as exportable HTML / CSV.

    Each external lookup is wrapped defensively: when a prerequisite connection is not
    configured or fails, dependent checks degrade to WARN with the reason rather than
    crashing the run. BLOCK is reserved for a definitively unsafe, verified state
    (e.g. a source mailbox confirmed on hold).

    GUARDRAIL #4: the exact output shapes of Get-Mailbox (hold properties),
    Get-MigrationEndpoint, Get-OrganizationRelationship, Get-SPOCrossTenantRelationship,
    and Get-MgSubscribedSku must be re-verified against a live tenant before relying on a
    PASS. Until then a PASS means "the cmdlet returned the expected shape", not a guarantee.

    Depends on State.psm1 and Mapping.psm1 in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')

function Test-SvcConfigured {
    param([string[]]$Values)
    foreach ($v in $Values) { if ($script:Placeholders -contains $v) { return $false } }
    return $true
}

function Connect-Service {
    # Returns @{ ok=$bool; error=$string }. Service = Graph|Exo|Spo. Tenant = config tenant obj.
    param([string]$Service, $Tenant)
    try {
        switch ($Service) {
            'Graph' {
                if (-not (Test-SvcConfigured @($Tenant.tenantId, $Tenant.graph.appId, $Tenant.graph.certThumbprint))) { return @{ ok = $false; error = 'Graph not configured' } }
                Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
                Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
                Connect-MgGraph -ClientId $Tenant.graph.appId -TenantId $Tenant.tenantId -CertificateThumbprint $Tenant.graph.certThumbprint -NoWelcome -ErrorAction Stop
            }
            'Exo' {
                $e = $Tenant.exchangeOnline
                if (-not (Test-SvcConfigured @($e.appId, $e.certThumbprint, $e.organization))) { return @{ ok = $false; error = 'Exchange Online not configured' } }
                Import-Module ExchangeOnlineManagement -ErrorAction Stop
                Connect-ExchangeOnline -AppId $e.appId -Organization $e.organization -CertificateThumbprint $e.certThumbprint -ShowBanner:$false -ShowProgress:$false -ErrorAction Stop
            }
            'Spo' {
                $s = $Tenant.sharePoint
                if (-not (Test-SvcConfigured @($s.appId, $s.certThumbprint, $s.adminUrl))) { return @{ ok = $false; error = 'SharePoint not configured' } }
                Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop
                Connect-SPOService -Url $s.adminUrl -ClientId $s.appId -CertificateThumbprint $s.certThumbprint -TenantId $Tenant.tenantId -ErrorAction Stop
            }
        }
        return @{ ok = $true; error = $null }
    }
    catch { return @{ ok = $false; error = $_.Exception.Message } }
}

function Disconnect-Service {
    param([string]$Service)
    try {
        switch ($Service) {
            'Graph' { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
            'Exo'   { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
            'Spo'   { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null }
        }
    }
    catch { }
}

function Invoke-Preflight {
    <#
    .SYNOPSIS
        Runs the full read-only preflight over the current mapping set and saves results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$RunId
    )

    $results = [System.Collections.Generic.List[object]]::new()
    function Add-Result {
        param([string]$Scope, [string]$Subject, [string]$Check, [ValidateSet('PASS', 'WARN', 'BLOCK')][string]$Status, [string]$Reason)
        $results.Add([ordered]@{ scope = $Scope; subject = $Subject; check = $Check; status = $Status; reason = $Reason })
    }

    $source = $Config.tenants.source
    $target = $Config.tenants.target
    $mappings = Get-Mappings
    $candidates = @($mappings | Where-Object { $_.matchState -eq 'matched' -and $_.targetUpn })

    if (@($mappings).Count -eq 0) {
        Add-Result 'tenant' '-' 'Mapping set present' 'BLOCK' 'No mappings exist. Build the identity mapping first (Phase 2).'
    }

    # ---------- Target tenant checks (EXO) ----------
    $targetMailUsers = @{}
    $exoT = Connect-Service -Service 'Exo' -Tenant $target
    if ($exoT.ok) {
        # Migration endpoint
        try {
            $eps = @(Get-MigrationEndpoint -ErrorAction Stop)
            if ($eps.Count -gt 0) { Add-Result 'tenant' 'target' 'Migration endpoint present' 'PASS' "$($eps.Count) endpoint(s)" }
            else { Add-Result 'tenant' 'target' 'Migration endpoint present' 'WARN' 'No migration endpoint found (created in Phase 4).' }
        }
        catch { Add-Result 'tenant' 'target' 'Migration endpoint present' 'WARN' "Could not query: $($_.Exception.Message)" }

        # Organization relationship with mailbox-move capability
        try {
            $orgs = @(Get-OrganizationRelationship -ErrorAction Stop)
            $moveCapable = $orgs | Where-Object { $_.PSObject.Properties.Name -contains 'MailboxMoveCapability' -and $_.MailboxMoveCapability } |
                Select-Object -First 1
            if ($moveCapable) { Add-Result 'tenant' 'target' 'Organization relationship (mailbox move)' 'PASS' "$($moveCapable.Identity)" }
            elseif ($orgs.Count -gt 0) { Add-Result 'tenant' 'target' 'Organization relationship (mailbox move)' 'WARN' 'Relationship exists but mailbox-move capability not set.' }
            else { Add-Result 'tenant' 'target' 'Organization relationship (mailbox move)' 'WARN' 'No organization relationship found (created in Phase 4).' }
        }
        catch { Add-Result 'tenant' 'target' 'Organization relationship (mailbox move)' 'WARN' "Could not query: $($_.Exception.Message)" }

        # Per-target MailUser existence (bulk per-upn lookup)
        foreach ($m in $candidates) {
            try {
                Get-MailUser -Identity $m.targetUpn -ErrorAction Stop | Out-Null
                $targetMailUsers[$m.targetUpn] = $true
            }
            catch { $targetMailUsers[$m.targetUpn] = $false }
        }
    }
    else {
        Add-Result 'tenant' 'target' 'Migration endpoint present' 'WARN' "Target Exchange Online not connected: $($exoT.error)"
        Add-Result 'tenant' 'target' 'Organization relationship (mailbox move)' 'WARN' "Target Exchange Online not connected: $($exoT.error)"
    }
    Disconnect-Service -Service 'Exo'

    # ---------- Target tenant: Cross Tenant add-on (Graph) ----------
    $gT = Connect-Service -Service 'Graph' -Tenant $target
    if ($gT.ok) {
        try {
            $skus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
            $addon = $skus | Where-Object {
                ($_.SkuPartNumber -match 'Cross.*Tenant.*Migration|Migration') -or
                (@($_.ServicePlans) | Where-Object { $_.ServicePlanName -match 'Cross.*Tenant|Migration' })
            } | Select-Object -First 1
            if ($addon) { Add-Result 'tenant' 'target' 'Cross Tenant User Data Migration add-on' 'PASS' "SKU $($addon.SkuPartNumber) (verify exact SKU live)" }
            else { Add-Result 'tenant' 'target' 'Cross Tenant User Data Migration add-on' 'WARN' 'No matching add-on SKU found on target. Verify the add-on is purchased/assigned.' }
        }
        catch { Add-Result 'tenant' 'target' 'Cross Tenant User Data Migration add-on' 'WARN' "Could not query subscribed SKUs: $($_.Exception.Message)" }
    }
    else { Add-Result 'tenant' 'target' 'Cross Tenant User Data Migration add-on' 'WARN' "Target Graph not connected: $($gT.error)" }
    Disconnect-Service -Service 'Graph'

    # ---------- Target tenant: SPO cross-tenant relationship ----------
    $spoT = Connect-Service -Service 'Spo' -Tenant $target
    if ($spoT.ok) {
        try {
            $rel = @(Get-SPOCrossTenantRelationship -ErrorAction Stop)
            if ($rel.Count -gt 0) { Add-Result 'tenant' 'target' 'SPO cross-tenant relationship' 'PASS' 'Relationship present' }
            else { Add-Result 'tenant' 'target' 'SPO cross-tenant relationship' 'WARN' 'No SPO cross-tenant relationship (created in Phase 4).' }
        }
        catch { Add-Result 'tenant' 'target' 'SPO cross-tenant relationship' 'WARN' "Could not query: $($_.Exception.Message)" }
    }
    else { Add-Result 'tenant' 'target' 'SPO cross-tenant relationship' 'WARN' "Target SharePoint not connected: $($spoT.error)" }
    Disconnect-Service -Service 'Spo'

    # ---------- Source tenant checks (EXO): holds ----------
    $sourceHolds = @{}
    $exoS = Connect-Service -Service 'Exo' -Tenant $source
    if ($exoS.ok) {
        foreach ($m in $candidates) {
            try {
                $mbx = Get-Mailbox -Identity $m.sourceUpn -ErrorAction Stop
                $onHold = ($mbx.LitigationHoldEnabled) -or
                          (@($mbx.InPlaceHolds).Count -gt 0) -or
                          ($mbx.PSObject.Properties.Name -contains 'ComplianceTagHoldApplied' -and $mbx.ComplianceTagHoldApplied)
                $sourceHolds[$m.sourceUpn] = @{ found = $true; onHold = [bool]$onHold }
            }
            catch { $sourceHolds[$m.sourceUpn] = @{ found = $false; onHold = $null; error = $_.Exception.Message } }
        }
    }
    Disconnect-Service -Service 'Exo'

    # ---------- Compose per-user results ----------
    foreach ($m in $candidates) {
        $upn = $m.sourceUpn

        # target MailUser exists
        if ($exoT.ok) {
            if ($targetMailUsers[$m.targetUpn]) { Add-Result 'user' $upn 'Target MailUser exists' 'PASS' $m.targetUpn }
            else { Add-Result 'user' $upn 'Target MailUser exists' 'BLOCK' "No MailUser '$($m.targetUpn)' in target. Provision before moving." }
        }
        else { Add-Result 'user' $upn 'Target MailUser exists' 'WARN' "Target Exchange Online not connected: $($exoT.error)" }

        # source mailbox hold
        if ($exoS.ok) {
            $h = $sourceHolds[$upn]
            if (-not $h.found) { Add-Result 'user' $upn 'Source mailbox not on hold' 'WARN' "Source mailbox not found or unreadable: $($h.error)" }
            elseif ($h.onHold) { Add-Result 'user' $upn 'Source mailbox not on hold' 'BLOCK' 'Source mailbox is on hold — blocked from cross-tenant move. Remove the hold first.' }
            else { Add-Result 'user' $upn 'Source mailbox not on hold' 'PASS' 'No litigation/in-place/tag hold detected.' }
        }
        else { Add-Result 'user' $upn 'Source mailbox not on hold' 'WARN' "Source Exchange Online not connected: $($exoS.error)" }
    }

    # ---------- Persist ----------
    $pass = @($results | Where-Object { $_.status -eq 'PASS' }).Count
    $warn = @($results | Where-Object { $_.status -eq 'WARN' }).Count
    $block = @($results | Where-Object { $_.status -eq 'BLOCK' }).Count
    $now = [DateTime]::UtcNow.ToString('o')

    Invoke-DbQuery -Query @'
INSERT INTO preflight_runs (run_id, created_utc, pass_count, warn_count, block_count)
VALUES (@id, @t, @p, @w, @b);
'@ -SqlParameters @{ id = $RunId; t = $now; p = $pass; w = $warn; b = $block } | Out-Null

    foreach ($r in $results) {
        Invoke-DbQuery -Query @'
INSERT INTO preflight_results (run_id, scope, subject, check_name, status, reason, created_utc)
VALUES (@run, @scope, @subject, @check, @status, @reason, @t);
'@ -SqlParameters @{
            run = $RunId; scope = $r.scope; subject = $r.subject; check = $r.check
            status = $r.status; reason = $r.reason; t = $now
        } | Out-Null
    }

    return (Get-PreflightRun -RunId $RunId)
}

function Get-PreflightRun {
    [CmdletBinding()]
    param([string]$RunId)

    if (-not $RunId) {
        $first = @(Invoke-DbQuery -Query 'SELECT run_id FROM preflight_runs ORDER BY created_utc DESC LIMIT 1;') | Select-Object -First 1
        if ($first) { $RunId = $first.run_id }
    }
    if (-not $RunId) { return $null }

    $run = @(Invoke-DbQuery -Query 'SELECT * FROM preflight_runs WHERE run_id = @id;' -SqlParameters @{ id = $RunId }) | Select-Object -First 1
    $rows = Invoke-DbQuery -Query @'
SELECT scope, subject, check_name, status, reason FROM preflight_results
WHERE run_id = @id
ORDER BY CASE status WHEN 'BLOCK' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, scope, subject;
'@ -SqlParameters @{ id = $RunId }

    return [ordered]@{
        runId      = $RunId
        createdUtc = $run.created_utc
        pass       = $run.pass_count
        warn       = $run.warn_count
        block      = $run.block_count
        results    = @($rows) | ForEach-Object {
            [ordered]@{ scope = $_.scope; subject = $_.subject; check = $_.check_name; status = $_.status; reason = $_.reason }
        }
    }
}

function ConvertTo-PreflightHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Report)

    $color = @{ PASS = '#1e8e3e'; WARN = '#b06f00'; BLOCK = '#c5221f' }
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $rowsHtml = ($Report.results | ForEach-Object {
        $c = $color[$_.status]
        "<tr><td>$($_.scope)</td><td>$(& $enc $_.subject)</td><td>$(& $enc $_.check)</td>" +
        "<td><b style='color:$c'>$($_.status)</b></td><td>$(& $enc $_.reason)</td></tr>"
    }) -join "`n"

    return @"
<!doctype html><html><head><meta charset="utf-8"><title>Preflight report $($Report.runId)</title>
<style>
body{font-family:system-ui,Segoe UI,Roboto,sans-serif;margin:2rem;color:#1a1a1a}
h1{font-size:1.3rem} .meta{color:#555;margin-bottom:1rem}
.summary span{display:inline-block;margin-right:1rem;font-weight:600}
table{border-collapse:collapse;width:100%;font-size:.9rem;margin-top:1rem}
th,td{border:1px solid #ddd;padding:.4rem .6rem;text-align:left;vertical-align:top}
th{background:#f5f5f5}
</style></head><body>
<h1>M365 cross-tenant preflight report</h1>
<div class="meta">Run <code>$($Report.runId)</code> &middot; generated $($Report.createdUtc)</div>
<div class="summary">
  <span style="color:#1e8e3e">PASS: $($Report.pass)</span>
  <span style="color:#b06f00">WARN: $($Report.warn)</span>
  <span style="color:#c5221f">BLOCK: $($Report.block)</span>
</div>
<table><thead><tr><th>Scope</th><th>Subject</th><th>Check</th><th>Status</th><th>Reason</th></tr></thead>
<tbody>
$rowsHtml
</tbody></table>
</body></html>
"@
}

function ConvertTo-PreflightCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Report)
    $rows = $Report.results | ForEach-Object {
        [pscustomobject]@{ Scope = $_.scope; Subject = $_.subject; Check = $_.check; Status = $_.status; Reason = $_.reason }
    }
    return (($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n")
}

Export-ModuleMember -Function Invoke-Preflight, Get-PreflightRun, ConvertTo-PreflightHtml, ConvertTo-PreflightCsv

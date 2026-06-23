#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    OneDrive + SharePoint cross-tenant content moves (Phase 6). Direct PS7 (Phase 0 decision).
.DESCRIPTION
    Bulk OneDrive account moves and SharePoint site moves via the SharePoint Online
    cross-tenant content-move cmdlets, which run on the SOURCE tenant against the partner
    (target) host URL.

    ONE-AND-DONE: cross-tenant content moves have NO incremental/delta passes. A given source
    can have only one job (enforced by a unique index), and the read-only window / cutover
    timing are explicit (PreferredMoveBeginDate / PreferredMoveEndDate). Validation
    (-ValidationOnly) is offered before the real, -Force move.

    Cmdlet syntax VERIFIED offline against Microsoft.Online.SharePoint.PowerShell (binary
    module), so these calls are exact (unlike the EXO REST cmdlets):
      Start-SPOCrossTenantUserContentMove -SourceUserPrincipalName -TargetUserPrincipalName
            -TargetCrossTenantHostUrl [-PreferredMoveBeginDate] [-PreferredMoveEndDate] [-ValidationOnly] [-Force]
      Start-SPOCrossTenantSiteContentMove -SourceSiteUrl -TargetSiteUrl -TargetCrossTenantHostUrl [...]
      Get-SPOCrossTenant{User,Site}ContentMoveState -PartnerCrossTenantHostUrl -Source...
      Stop-SPOCrossTenant{User,Site}ContentMove -Source...

    Depends on State.psm1, Logging.psm1 in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')

function Test-SpoConfigured {
    param($Tenant)
    $s = $Tenant.sharePoint
    return (($script:Placeholders -notcontains $s.appId) -and ($script:Placeholders -notcontains $s.certThumbprint) -and ($script:Placeholders -notcontains $s.adminUrl))
}
function Connect-TenantSpo {
    param($Tenant)
    $s = $Tenant.sharePoint
    Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop
    Connect-SPOService -Url $s.adminUrl -ClientId $s.appId -Certificate (Get-SpoCertificate $s.certThumbprint) -TenantId $Tenant.tenantId -ErrorAction Stop
}
function Disconnect-Spo { try { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null } catch { } }
function Connect-TenantGraph {
    param($Tenant)
    Import-GraphModules   # exported from Connections.psm1 (avoids the Graph assembly-load conflict)
    Connect-MgGraph -ClientId $Tenant.graph.appId -TenantId $Tenant.tenantId -CertificateThumbprint $Tenant.graph.certThumbprint -NoWelcome -ErrorAction Stop
}
function Assert-CmdletReady {
    param([string]$Name, [string[]]$RequiredParameters = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Cmdlet '$Name' not available (not connected?). Verify before use (guardrail #4)." }
    $missing = @($RequiredParameters | Where-Object { $_ -notin @($cmd.Parameters.Keys) })
    if ($missing.Count -gt 0) { throw "Cmdlet '$Name' missing parameter(s): $($missing -join ', ') (guardrail #4)." }
}
function Disconnect-Graph { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }

function ConvertTo-MoveStatus {
    param([string]$State)
    switch ($State) {
        'Success'      { 'success'; break }
        'Failed'       { 'failed'; break }
        'NotSupported' { 'failed'; break }
        'Stopped'      { 'stopped'; break }
        'InProgress'   { 'inprogress'; break }
        'Queued'       { 'scheduled'; break }
        'Rescheduled'  { 'scheduled'; break }
        'NotStarted'   { 'created'; break }
        default { if ($State) { $State.ToLowerInvariant() } else { 'unknown' } }
    }
}

function Write-FileMoveSnapshot {
    param([string]$Tag, $Data)
    $snapDir = Join-Path (Split-Path $env:MIG_DB_PATH -Parent) 'snapshots'
    if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
    ($Data | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $snapDir "$Tag.json") -Encoding utf8
}

function Get-PartnerTargetHostUrl {
    # The target tenant's cross-tenant host URL (used as -TargetCrossTenantHostUrl / partner).
    param($Config)
    $tgt = $Config.tenants.target
    if (-not (Test-SpoConfigured $tgt)) { throw 'SharePoint is not configured for the target tenant.' }
    try {
        Connect-TenantSpo -Tenant $tgt
        # Get-SPOCrossTenantHostUrl returns a verbose multi-line blob; extract the bare URL
        # (the -my MySiteHost root, e.g. https://reformeaorg-my.sharepoint.com).
        $raw = [string](Get-SPOCrossTenantHostUrl -ErrorAction Stop)
        $m = [regex]::Match($raw, 'https?://[^\s/]+\.sharepoint\.com')
        if (-not $m.Success) { throw "Could not parse cross-tenant host URL from: $raw" }
        return $m.Value
    }
    finally { Disconnect-Spo }
}

function Get-SourceSites {
    <#
    .SYNOPSIS
        Lists source SharePoint site collections (read-only) for the GUI picker.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Config)
    $src = $Config.tenants.source
    if (-not (Test-SpoConfigured $src)) { throw 'SharePoint is not configured for the source tenant.' }
    try {
        Connect-TenantSpo -Tenant $src
        $sites = Get-SPOSite -Limit All -ErrorAction Stop | Where-Object { $_.Url -match '/sites/' }
        return @($sites | ForEach-Object {
                [ordered]@{
                    url      = [string]$_.Url
                    title    = [string]$_.Title
                    template = [string]$_.Template
                    isGroup  = ([string]$_.Template -like 'GROUP*')
                    storageMb = [int]$_.StorageUsageCurrent
                }
            } | Sort-Object { $_.url })
    }
    finally { Disconnect-Spo }
}

function Get-TargetSiteRoot {
    # Derive the target SPO root (https://<tenant>.sharepoint.com) from the admin URL.
    param($Config)
    $admin = [string]$Config.tenants.target.sharePoint.adminUrl
    return ($admin -replace '-admin\.sharepoint\.com', '.sharepoint.com')
}

function Get-DerivedTargetUrl {
    <#
    .SYNOPSIS
        Maps a source site URL to the equivalent target URL (same path under target host).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$SourceUrl)
    $path = ([uri]$SourceUrl).AbsolutePath   # e.g. /sites/Test-site
    return ((Get-TargetSiteRoot -Config $Config).TrimEnd('/') + $path)
}

function Get-SiteAlias {
    # Group alias / mailNickname from the site URL (segment after /sites/).
    param([string]$Url)
    return (([uri]$Url).AbsolutePath.TrimEnd('/') -split '/')[-1]
}

function Invoke-SiteMigration {
    <#
    .SYNOPSIS
        End-to-end site migration for a picked source site: provision the target, validate,
        then migrate. Group-connected sites use the group engine (target M365 group created
        first); plain sites use the site engine.
    .PARAMETER Action
        provision | validate | migrate. provision + migrate are gated mutations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][ValidateSet('provision', 'validate', 'migrate')][string]$Action,
        [datetime]$PreferredBegin, [datetime]$PreferredEnd
    )
    $src = $Config.tenants.source
    if (-not (Test-SpoConfigured $src)) { throw 'SharePoint is not configured for the source tenant.' }

    # Source site facts.
    $template = $null; $title = $null
    try {
        Connect-TenantSpo -Tenant $src
        $site = Get-SPOSite -Identity $SourceUrl -ErrorAction Stop
        $template = [string]$site.Template; $title = [string]$site.Title
    }
    finally { Disconnect-Spo }
    $isGroup = $template -like 'GROUP*'
    $alias = Get-SiteAlias $SourceUrl
    $targetUrl = Get-DerivedTargetUrl -Config $Config -SourceUrl $SourceUrl
    $targetHost = Get-PartnerTargetHostUrl -Config $Config

    # ---- provision the target ----
    if ($Action -eq 'provision') {
        if ($isGroup) {
            try {
                Connect-TenantGraph -Tenant $Config.tenants.target
                $existing = @(Get-MgGroup -Filter "mailNickname eq '$alias'" -ErrorAction Stop)
                if (@($existing).Count -gt 0) { return @{ ok = $true; provisioned = $false; isGroup = $true; targetUrl = $targetUrl; detail = "Target group '$alias' already exists." } }
                Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action 'filemove.group.provision' -Target $alias -Detail "Create target M365 group for $SourceUrl"
                New-MgGroup -DisplayName $title -MailNickname $alias -GroupTypes @('Unified') -MailEnabled:$true -SecurityEnabled:$false -ErrorAction Stop | Out-Null
                return @{ ok = $true; provisioned = $true; isGroup = $true; targetUrl = $targetUrl; detail = "Created target M365 group '$alias'. Its SharePoint site provisions within a few minutes — wait before validating." }
            }
            catch { return @{ ok = $false; isGroup = $true; error = $_.Exception.Message } }
            finally { Disconnect-Graph }
        }
        else {
            return @{ ok = $false; isGroup = $false; error = 'Auto-provisioning of non-group sites is not implemented yet (needs owner + template). Create the target site manually, then Validate.' }
        }
    }

    # ---- validate / migrate (run on the SOURCE SPO connection) ----
    $force = ($Action -eq 'migrate')
    $cmd = if ($isGroup) {
        @{ name = 'Start-SPOCrossTenantGroupContentMove'; src = 'SourceGroupAlias'; tgt = 'TargetGroupAlias'; srcVal = $alias; tgtVal = $alias; jobType = 'group'; jobSrc = $alias; jobTgt = $alias }
    }
    else {
        @{ name = 'Start-SPOCrossTenantSiteContentMove'; src = 'SourceSiteUrl'; tgt = 'TargetSiteUrl'; srcVal = $SourceUrl; tgtVal = $targetUrl; jobType = 'site'; jobSrc = $SourceUrl; jobTgt = $targetUrl }
    }

    if ($force) {
        $dup = @(Invoke-DbQuery -Query 'SELECT job_id FROM file_move_jobs WHERE type=@t AND source=@s;' -SqlParameters @{ t = $cmd.jobType; s = $cmd.jobSrc }) | Select-Object -First 1
        if ($dup) { throw "A $($cmd.jobType) move already exists for '$($cmd.jobSrc)'. Cross-tenant moves cannot be re-run incrementally." }
    }

    try {
        Connect-TenantSpo -Tenant $src
        $params = @{ $cmd.src = $cmd.srcVal; $cmd.tgt = $cmd.tgtVal; TargetCrossTenantHostUrl = $targetHost }
        if ($PSBoundParameters.ContainsKey('PreferredBegin')) { $params.PreferredMoveBeginDate = $PreferredBegin }
        if ($PSBoundParameters.ContainsKey('PreferredEnd')) { $params.PreferredMoveEndDate = $PreferredEnd }
        if ($force) { $params.Force = $true } else { $params.ValidationOnly = $true }
        Assert-CmdletReady -Name $cmd.name -RequiredParameters @($params.Keys)

        if ($force) {
            Write-FileMoveSnapshot -Tag "sitemigrate-$($cmd.jobType)-$alias" -Data @{ source = $cmd.jobSrc; target = $cmd.jobTgt; isGroup = $isGroup; targetHost = $targetHost }
            Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action "filemove.$($cmd.jobType).start" -Target $cmd.jobSrc -Detail "-> $($cmd.jobTgt) (one-and-done)"
        }
        $result = & $cmd.name @params -ErrorAction Stop

        if ($force) {
            $jobId = 'fm-{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')), ([guid]::NewGuid().ToString('N').Substring(0, 4))
            $now = [DateTime]::UtcNow.ToString('o')
            Invoke-DbQuery -Query @'
INSERT INTO file_move_jobs (job_id, type, source, target, target_host_url, status, correlation_id, created_utc, updated_utc, notes)
VALUES (@id, @type, @src, @tgt, @host, 'scheduled', @corr, @t, @t, 'One-and-done cross-tenant move.');
'@ -SqlParameters @{ id = $jobId; type = $cmd.jobType; src = $cmd.jobSrc; tgt = $cmd.jobTgt; host = $targetHost; corr = (New-CorrelationId); t = $now } | Out-Null
            return @{ ok = $true; action = 'migrate'; isGroup = $isGroup; jobId = $jobId; detail = "Move started for '$($cmd.jobSrc)'." }
        }
        return @{ ok = $true; action = 'validate'; isGroup = $isGroup; detail = (($result | Out-String).Trim()) }
    }
    catch { return @{ ok = $false; action = $Action; isGroup = $isGroup; error = $_.Exception.Message } }
    finally { Disconnect-Spo }
}

# Per-type cmdlet names + identity parameter mapping.
function Get-MoveCmdlets {
    param([string]$Type)
    switch ($Type) {
        'onedrive' { return @{ start = 'Start-SPOCrossTenantUserContentMove'; state = 'Get-SPOCrossTenantUserContentMoveState'; stop = 'Stop-SPOCrossTenantUserContentMove'; srcParam = 'SourceUserPrincipalName'; tgtParam = 'TargetUserPrincipalName' } }
        'site'     { return @{ start = 'Start-SPOCrossTenantSiteContentMove'; state = 'Get-SPOCrossTenantSiteContentMoveState'; stop = 'Stop-SPOCrossTenantSiteContentMove'; srcParam = 'SourceSiteUrl'; tgtParam = 'TargetSiteUrl' } }
        'group'    { return @{ start = 'Start-SPOCrossTenantGroupContentMove'; state = 'Get-SPOCrossTenantGroupContentMoveState'; stop = 'Stop-SPOCrossTenantGroupContentMove'; srcParam = 'SourceGroupAlias'; tgtParam = 'TargetGroupAlias' } }
        default    { throw "Unknown move type '$Type'." }
    }
}

function Test-FileMove {
    <#
    .SYNOPSIS
        Read-only pre-move validation (-ValidationOnly). Does not move anything.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][ValidateSet('onedrive', 'site')][string]$Type,
        [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)

    $src = $Config.tenants.source
    if (-not (Test-SpoConfigured $src)) { throw 'SharePoint is not configured for the source tenant.' }
    $cmd = Get-MoveCmdlets $Type
    $tgtHost = Get-PartnerTargetHostUrl -Config $Config

    try {
        Connect-TenantSpo -Tenant $src
        $params = @{ $cmd.srcParam = $Source; $cmd.tgtParam = $Target; TargetCrossTenantHostUrl = $tgtHost; ValidationOnly = $true }
        $result = & $cmd.start @params -ErrorAction Stop
        return @{ ok = $true; type = $Type; source = $Source; target = $Target; result = ($result | Out-String).Trim() }
    }
    catch { return @{ ok = $false; type = $Type; source = $Source; target = $Target; error = $_.Exception.Message } }
    finally { Disconnect-Spo }
}

function Start-FileMove {
    <#
    .SYNOPSIS
        Starts a real (one-and-done) cross-tenant content move (-Force). Gated; snapshots.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('onedrive', 'site')][string]$Type,
        [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target,
        [datetime]$PreferredBegin, [datetime]$PreferredEnd
    )
    $src = $Config.tenants.source
    if (-not (Test-SpoConfigured $src)) { throw 'SharePoint is not configured for the source tenant.' }

    # One-and-done: refuse if a job already exists for this source/type.
    $existing = @(Invoke-DbQuery -Query 'SELECT job_id, status FROM file_move_jobs WHERE type=@t AND source=@s;' -SqlParameters @{ t = $Type; s = $Source }) | Select-Object -First 1
    if ($existing) { throw "A $Type move already exists for '$Source' (status: $($existing.status)). Cross-tenant moves cannot be re-run incrementally." }

    $cmd = Get-MoveCmdlets $Type
    $tgtHost = Get-PartnerTargetHostUrl -Config $Config
    $jobId = 'fm-{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')), ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $corr = New-CorrelationId

    try {
        Connect-TenantSpo -Tenant $src
        $params = @{ $cmd.srcParam = $Source; $cmd.tgtParam = $Target; TargetCrossTenantHostUrl = $tgtHost; Force = $true }
        if ($PSBoundParameters.ContainsKey('PreferredBegin')) { $params.PreferredMoveBeginDate = $PreferredBegin }
        if ($PSBoundParameters.ContainsKey('PreferredEnd')) { $params.PreferredMoveEndDate = $PreferredEnd }

        Write-FileMoveSnapshot -Tag "filemove-start-$jobId" -Data @{ type = $Type; source = $Source; target = $Target; targetHostUrl = $tgtHost; preferredBegin = $PreferredBegin; preferredEnd = $PreferredEnd; oneAndDone = $true }
        Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action "filemove.$Type.start" -Target $Source -Detail "-> $Target (one-and-done, no delta)"
        & $cmd.start @params -ErrorAction Stop | Out-Null
    }
    finally { Disconnect-Spo }

    $now = [DateTime]::UtcNow.ToString('o')
    Invoke-DbQuery -Query @'
INSERT INTO file_move_jobs (job_id, type, source, target, target_host_url, status, preferred_begin, preferred_end, correlation_id, created_utc, updated_utc, notes)
VALUES (@id, @type, @src, @tgt, @host, 'scheduled', @pb, @pe, @corr, @t, @t, 'One-and-done: cannot be re-run incrementally.');
'@ -SqlParameters @{
        id = $jobId; type = $Type; src = $Source; tgt = $Target; host = $tgtHost
        pb = ($(if ($PSBoundParameters.ContainsKey('PreferredBegin')) { $PreferredBegin.ToString('o') } else { $null }))
        pe = ($(if ($PSBoundParameters.ContainsKey('PreferredEnd')) { $PreferredEnd.ToString('o') } else { $null }))
        corr = $corr; t = $now
    } | Out-Null

    return Get-FileMoveJob -JobId $jobId
}

function Update-FileMoveState {
    <#
    .SYNOPSIS
        Polls the SPO move state and updates the job (resume-safe). Read-only on tenants.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$JobId)
    $job = Get-FileMoveJob -JobId $JobId
    if (-not $job) { throw 'Job not found.' }
    $src = $Config.tenants.source
    if (-not (Test-SpoConfigured $src)) { return @{ refreshed = $false; reason = 'Source SharePoint not configured' } }
    $cmd = Get-MoveCmdlets $job.type
    $tgtHost = $job.targetHostUrl
    if (-not $tgtHost) { $tgtHost = Get-PartnerTargetHostUrl -Config $Config }

    try {
        Connect-TenantSpo -Tenant $src
        $params = @{ PartnerCrossTenantHostUrl = $tgtHost; $cmd.srcParam = $job.source }
        $state = & $cmd.state @params -ErrorAction Stop | Select-Object -First 1
        $raw = if ($state -and ($state.PSObject.Properties.Name -contains 'MoveState')) { [string]$state.MoveState } else { [string]$state }
        $norm = ConvertTo-MoveStatus $raw
        $redirect = if ($norm -eq 'success') { 'Source redirected to target' } else { $null }
        $now = [DateTime]::UtcNow.ToString('o')
        Invoke-DbQuery -Query 'UPDATE file_move_jobs SET status=@s, move_state=@ms, redirect_status=@r, updated_utc=@t WHERE job_id=@id;' `
            -SqlParameters @{ s = $norm; ms = $raw; r = $redirect; t = $now; id = $JobId } | Out-Null
    }
    finally { Disconnect-Spo }
    return @{ refreshed = $true; job = (Get-FileMoveJob -JobId $JobId) }
}

function Stop-FileMove {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$JobId)
    $job = Get-FileMoveJob -JobId $JobId
    if (-not $job) { throw 'Job not found.' }
    $src = $Config.tenants.source
    $cmd = Get-MoveCmdlets $job.type
    try {
        Connect-TenantSpo -Tenant $src
        Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action "filemove.$($job.type).stop" -Target $job.source
        & $cmd.stop @{ $cmd.srcParam = $job.source } -ErrorAction Stop | Out-Null
        Invoke-DbQuery -Query 'UPDATE file_move_jobs SET status=''stopped'', updated_utc=@t WHERE job_id=@id;' -SqlParameters @{ t = [DateTime]::UtcNow.ToString('o'); id = $JobId } | Out-Null
    }
    finally { Disconnect-Spo }
    return Get-FileMoveJob -JobId $JobId
}

function Get-FileMoveJobs {
    [CmdletBinding()] param()
    $rows = Invoke-DbQuery -Query 'SELECT * FROM file_move_jobs ORDER BY created_utc DESC;'
    return @($rows) | ForEach-Object { ConvertFrom-JobRow $_ }
}
function Get-FileMoveJob {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$JobId)
    $r = @(Invoke-DbQuery -Query 'SELECT * FROM file_move_jobs WHERE job_id=@id;' -SqlParameters @{ id = $JobId }) | Select-Object -First 1
    if (-not $r) { return $null }
    return ConvertFrom-JobRow $r
}
function ConvertFrom-JobRow {
    param($Row)
    return [ordered]@{
        jobId = $Row.job_id; type = $Row.type; source = $Row.source; target = $Row.target
        targetHostUrl = $Row.target_host_url; status = $Row.status; moveState = $Row.move_state
        preferredBegin = $Row.preferred_begin; preferredEnd = $Row.preferred_end
        redirectStatus = $Row.redirect_status; createdUtc = $Row.created_utc; updatedUtc = $Row.updated_utc; notes = $Row.notes
    }
}

Export-ModuleMember -Function `
    Test-FileMove, Start-FileMove, Update-FileMoveState, Stop-FileMove, `
    Get-FileMoveJobs, Get-FileMoveJob, Get-SourceSites, Get-DerivedTargetUrl, Invoke-SiteMigration

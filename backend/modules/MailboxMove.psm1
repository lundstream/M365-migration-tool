#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Cross-tenant mailbox batch executor (Phase 5 — DESTRUCTIVE on finalize).
.DESCRIPTION
    Wraps New-MigrationBatch for cross-tenant moves with persisted SQLite state (resume after
    crash), throttling-aware retry honoring Retry-After, and per-item correlation IDs.

    SAFETY MODEL (BRIEF.md guardrail #1):
      - Creating/starting a batch only SYNCS data. It NEVER auto-completes — no -AutoComplete
        / -CompleteAfter parameter is ever passed.
      - Completion (Complete-MigrationBatch) DELETES the source mailbox. It is a SEPARATE,
        explicit operator action that is refused unless (a) every item is verified Synced and
        (b) the caller supplies a confirmation token equal to the batch name. A state snapshot
        is written to disk before completion, and the action is audited.

    GUARDRAIL #4: the EXO migration cmdlets (New-MigrationBatch, Get-MigrationBatch,
    Get-MigrationUser, Complete-MigrationBatch, Set-Mailbox) are post-connect REST cmdlets and
    could not be introspected offline. Every mutating call is preceded by Assert-CmdletReady,
    which aborts if the live cmdlet lacks an expected parameter. Batch parameters can be
    overridden via config.migration.batchParameters after live verification.

    Depends on State.psm1, Logging.psm1 in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')

function Test-ExoConfigured {
    param($Tenant)
    $e = $Tenant.exchangeOnline
    return (($script:Placeholders -notcontains $e.appId) -and ($script:Placeholders -notcontains $e.certThumbprint) -and ($script:Placeholders -notcontains $e.organization))
}
function Connect-TenantExo {
    param($Tenant)
    $e = $Tenant.exchangeOnline
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-ExchangeOnline -AppId $e.appId -Organization $e.organization -CertificateThumbprint $e.certThumbprint -ShowBanner:$false -ShowProgress:$false -ErrorAction Stop
}
function Disconnect-TenantExo { try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { } }

function Assert-CmdletReady {
    param([Parameter(Mandatory)][string]$Name, [string[]]$RequiredParameters = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Cmdlet '$Name' is not available (not connected, or module changed). Verify before use (guardrail #4)." }
    $missing = @($RequiredParameters | Where-Object { $_ -notin @($cmd.Parameters.Keys) })
    if ($missing.Count -gt 0) { throw "Cmdlet '$Name' is missing expected parameter(s): $($missing -join ', '). Confirm via 'Get-Command $Name -Syntax' (guardrail #4)." }
}

function ConvertTo-Splat {
    param($Object)
    $h = @{}
    if ($null -eq $Object) { return $h }
    foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Runs a scriptblock with bounded, throttling-aware retry honoring Retry-After.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$MaxAttempts = 5,
        [int]$DefaultDelaySeconds = 30,
        [string]$RunId
    )
    for ($attempt = 1; ; $attempt++) {
        try { return & $Action }
        catch {
            $msg = $_.Exception.Message
            $throttled = $msg -match 'throttl|Retry-After|TooManyRequests|\b429\b|MailboxReplicationThrottling|ServerBusy'
            if (-not $throttled -or $attempt -ge $MaxAttempts) { throw }
            $delay = $DefaultDelaySeconds
            if ($msg -match 'Retry-After[:\s]+(\d+)') { $delay = [int]$Matches[1] }
            $delay = [Math]::Min($delay, 300)
            if ($RunId) { Write-JsonLog -RunId $RunId -Level Warning -Message "Throttled; backing off ${delay}s (attempt $attempt)" }
            # Record for the monitor's throttling indicator (cross-runspace).
            if (Get-Command Set-AppState -ErrorAction SilentlyContinue) {
                try { Set-AppState -Key 'lastThrottleUtc' -Value ([DateTime]::UtcNow.ToString('o')) } catch { }
            }
            Start-Sleep -Seconds $delay
        }
    }
}

function ConvertTo-NormStatus {
    param([string]$Status)
    switch -Regex ($Status) {
        'Completed'                                   { 'completed'; break }
        'Completing|Finalizing'                       { 'completing'; break }
        'Synced|AutoSuspended|Suspended'              { 'synced'; break }
        'Failed'                                      { 'failed'; break }
        'Stopped|Removed|Corrupt'                     { 'stopped'; break }
        'Provisioning|Syncing|Starting|InProgress|Queued|Validating' { 'syncing'; break }
        default { if ($Status) { $Status.ToLowerInvariant() } else { 'unknown' } }
    }
}

function Write-MailboxSnapshot {
    param([string]$RunId, [string]$Tag, $Data)
    $snapDir = Join-Path (Split-Path $env:MIG_DB_PATH -Parent) 'snapshots'
    if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
    ($Data | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $snapDir "$Tag.json") -Encoding utf8
}

# ---------------- READ ----------------

function Get-MailboxBatches {
    [CmdletBinding()] param()
    $rows = Invoke-DbQuery -Query 'SELECT * FROM mailbox_batches ORDER BY created_utc DESC;'
    return @($rows) | ForEach-Object {
        [ordered]@{
            batchId = $_.batch_id; name = $_.name; status = $_.status
            itemCount = $_.item_count; targetDeliveryDomain = $_.target_delivery_domain
            createdUtc = $_.created_utc; updatedUtc = $_.updated_utc; completedUtc = $_.completed_utc
        }
    }
}

function Get-MailboxBatch {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$BatchId)
    $b = @(Invoke-DbQuery -Query 'SELECT * FROM mailbox_batches WHERE batch_id = @id;' -SqlParameters @{ id = $BatchId }) | Select-Object -First 1
    if (-not $b) { return $null }
    $items = Invoke-DbQuery -Query 'SELECT * FROM mailbox_batch_items WHERE batch_id = @id ORDER BY source_upn;' -SqlParameters @{ id = $BatchId }
    return [ordered]@{
        batchId = $b.batch_id; name = $b.name; exoBatchName = $b.exo_batch_name; status = $b.status
        sourceEndpoint = $b.source_endpoint; targetDeliveryDomain = $b.target_delivery_domain
        itemCount = $b.item_count; createdUtc = $b.created_utc; updatedUtc = $b.updated_utc; completedUtc = $b.completed_utc
        items = @($items) | ForEach-Object {
            [ordered]@{
                sourceUpn = $_.source_upn; targetUpn = $_.target_upn; status = $_.status
                exoStatus = $_.exo_status; percent = $_.percent; error = $_.error
                forwardingSet = [bool]$_.forwarding_set; lastStatusUtc = $_.last_status_utc
            }
        }
    }
}

function Test-BatchReadyToComplete {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$BatchId)
    $b = Get-MailboxBatch -BatchId $BatchId
    if (-not $b) { return @{ ready = $false; reason = 'Batch not found' } }
    $notSynced = @($b.items | Where-Object { $_.status -notin @('synced', 'completed') })
    if (@($b.items).Count -eq 0) { return @{ ready = $false; reason = 'Batch has no items' } }
    if ($notSynced.Count -gt 0) {
        return @{ ready = $false; reason = "$($notSynced.Count) of $(@($b.items).Count) item(s) not yet Synced"; notReady = @($notSynced | ForEach-Object { $_.sourceUpn }) }
    }
    return @{ ready = $true; reason = 'All items Synced' }
}

# ---------------- CREATE / START (sync only) ----------------

function New-MailboxBatch {
    <#
    .SYNOPSIS
        Creates + starts a cross-tenant migration batch (SYNC ONLY — never auto-completes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Items   # objects with .sourceUpn and .targetUpn
    )
    $tgt = $Config.tenants.target
    if (-not (Test-ExoConfigured $tgt)) { throw 'Target Exchange Online is not configured.' }
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Batch name is required.' }
    if (@($Items).Count -eq 0) { throw 'No users selected for the batch.' }

    $endpoint = $Config.migration.endpointName
    $tdd = $Config.migration.targetDeliveryDomain
    $sourceUpns = @($Items | ForEach-Object { $_.sourceUpn })
    $csv = "EmailAddress`r`n" + ($sourceUpns -join "`r`n")
    $csvBytes = [System.Text.Encoding]::UTF8.GetBytes($csv)

    # Best-effort cross-tenant params. NOTE: deliberately NO AutoComplete / CompleteAfter.
    $params = if ($Config.migration.batchParameters) { ConvertTo-Splat $Config.migration.batchParameters }
              else { @{ Name = $Name; SourceEndpoint = $endpoint; TargetDeliveryDomain = $tdd; CSVData = $csvBytes; AutoStart = $true } }
    if (-not $params.ContainsKey('CSVData')) { $params['CSVData'] = $csvBytes }

    $batchId = 'mbx-{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')), ([guid]::NewGuid().ToString('N').Substring(0, 4))

    try {
        Connect-TenantExo -Tenant $tgt
        $exists = $null
        try { $exists = Get-MigrationBatch -Identity $Name -ErrorAction Stop } catch { $exists = $null }
        if ($exists) { throw "A migration batch named '$Name' already exists in the target tenant." }

        # Verify the params we will pass actually exist; abort safely otherwise.
        $assertKeys = @($params.Keys | Where-Object { $_ -ne 'CSVData' }) + 'CSVData'
        Assert-CmdletReady -Name 'New-MigrationBatch' -RequiredParameters $assertKeys

        Write-MailboxSnapshot -RunId $RunId -Tag "mailbox-create-$batchId" -Data @{ name = $Name; sourceEndpoint = $endpoint; targetDeliveryDomain = $tdd; users = $sourceUpns; autoComplete = $false }
        Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action 'mailbox.batch.create' -Target $Name -Detail "users=$($sourceUpns.Count); sync-only (no auto-complete)"
        Invoke-WithRetry -RunId $RunId -Action { New-MigrationBatch @params -ErrorAction Stop } | Out-Null
    }
    finally { Disconnect-TenantExo }

    # Persist state.
    $now = [DateTime]::UtcNow.ToString('o')
    Invoke-DbQuery -Query @'
INSERT INTO mailbox_batches (batch_id, name, exo_batch_name, status, source_endpoint, target_delivery_domain, item_count, created_utc, updated_utc)
VALUES (@id, @name, @exo, 'syncing', @ep, @tdd, @count, @t, @t);
'@ -SqlParameters @{ id = $batchId; name = $Name; exo = $Name; ep = $endpoint; tdd = $tdd; count = $sourceUpns.Count; t = $now } | Out-Null

    foreach ($it in $Items) {
        Invoke-DbQuery -Query @'
INSERT INTO mailbox_batch_items (batch_id, source_upn, target_upn, correlation_id, status, last_status_utc)
VALUES (@bid, @src, @tgt, @corr, 'queued', @t);
'@ -SqlParameters @{ bid = $batchId; src = $it.sourceUpn; tgt = $it.targetUpn; corr = (New-CorrelationId); t = $now } | Out-Null
    }
    return Get-MailboxBatch -BatchId $batchId
}

# ---------------- POLL / RESUME ----------------

function Update-MailboxBatchStatus {
    <#
    .SYNOPSIS
        Reconciles persisted state with live EXO (resume-safe). Read-only on the tenant.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$BatchId)
    $b = Get-MailboxBatch -BatchId $BatchId
    if (-not $b) { throw 'Batch not found.' }
    $tgt = $Config.tenants.target
    if (-not (Test-ExoConfigured $tgt)) { return @{ refreshed = $false; reason = 'Target Exchange Online not configured' } }

    try {
        Connect-TenantExo -Tenant $tgt
        $batchStatus = $b.status
        try {
            $mb = Get-MigrationBatch -Identity $b.exoBatchName -ErrorAction Stop
            $batchStatus = ConvertTo-NormStatus ([string]$mb.Status)
        }
        catch { }

        $users = @()
        try { $users = @(Get-MigrationUser -BatchId $b.exoBatchName -ErrorAction Stop) }
        catch { try { $users = @(Get-MigrationUser -ErrorAction Stop | Where-Object { $_.BatchId -eq $b.exoBatchName }) } catch { } }

        $now = [DateTime]::UtcNow.ToString('o')
        foreach ($it in $b.items) {
            $u = $users | Where-Object { $_.Identity -eq $it.sourceUpn -or $_.EmailAddress -eq $it.sourceUpn } | Select-Object -First 1
            if (-not $u) { continue }
            $norm = ConvertTo-NormStatus ([string]$u.Status)
            $pct = $null
            if ($u.PSObject.Properties.Name -contains 'PercentageComplete') { $pct = [int]$u.PercentageComplete }
            Invoke-DbQuery -Query 'UPDATE mailbox_batch_items SET status=@s, exo_status=@es, percent=@p, last_status_utc=@t WHERE batch_id=@b AND source_upn=@u;' `
                -SqlParameters @{ s = $norm; es = [string]$u.Status; p = $pct; t = $now; b = $BatchId; u = $it.sourceUpn } | Out-Null
        }
        Invoke-DbQuery -Query 'UPDATE mailbox_batches SET status=@s, updated_utc=@t WHERE batch_id=@b;' -SqlParameters @{ s = $batchStatus; t = $now; b = $BatchId } | Out-Null
    }
    finally { Disconnect-TenantExo }

    return @{ refreshed = $true; batch = (Get-MailboxBatch -BatchId $BatchId) }
}

# ---------------- FORWARDING (gated, source mutation) ----------------

function Set-SourceForwarding {
    <#
    .SYNOPSIS
        Sets ForwardingSmtpAddress on the SOURCE mailboxes to the target address.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$BatchId)
    $b = Get-MailboxBatch -BatchId $BatchId
    if (-not $b) { throw 'Batch not found.' }
    $src = $Config.tenants.source
    if (-not (Test-ExoConfigured $src)) { throw 'Source Exchange Online is not configured.' }

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        Connect-TenantExo -Tenant $src
        Assert-CmdletReady -Name 'Set-Mailbox' -RequiredParameters @('Identity', 'ForwardingSmtpAddress', 'DeliverToMailboxAndForward')
        foreach ($it in $b.items) {
            if (-not $it.targetUpn) { $results.Add(@{ sourceUpn = $it.sourceUpn; status = 'skipped'; reason = 'no target address' }); continue }
            $corr = New-CorrelationId
            try {
                Invoke-WithRetry -RunId $RunId -Action {
                    Set-Mailbox -Identity $it.sourceUpn -ForwardingSmtpAddress $it.targetUpn -DeliverToMailboxAndForward $true -ErrorAction Stop
                } | Out-Null
                Invoke-DbQuery -Query 'UPDATE mailbox_batch_items SET forwarding_set=1 WHERE batch_id=@b AND source_upn=@u;' -SqlParameters @{ b = $BatchId; u = $it.sourceUpn } | Out-Null
                Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'mailbox.forwarding.set' -Target $it.sourceUpn -Detail "-> $($it.targetUpn)"
                $results.Add(@{ sourceUpn = $it.sourceUpn; status = 'set'; target = $it.targetUpn })
            }
            catch { $results.Add(@{ sourceUpn = $it.sourceUpn; status = 'failed'; reason = $_.Exception.Message }) }
        }
    }
    finally { Disconnect-TenantExo }
    return @{ batchId = $BatchId; results = $results }
}

function Set-MappingForwarding {
    <#
    .SYNOPSIS
        Cutover forwarding for the COPY workflow: sets (or clears) ForwardingSmtpAddress on the
        SOURCE mailboxes to their matched target address, so new mail flows to the new tenant.
    .DESCRIPTION
        Drives off the mappings table (not native batches). Server-side forwarding via
        Set-Mailbox -ForwardingSmtpAddress (admin-set; not a user inbox rule). KeepCopy maps to
        -DeliverToMailboxAndForward: $true leaves a copy in the old mailbox too (safer during
        transition), $false forwards only. -Remove clears forwarding again.
        Targets only 'matched' mappings with a target address; an optional SourceUpns subset
        narrows it further.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string]$RunId,
        [string[]]$SourceUpns,
        [bool]$KeepCopy = $true,
        [switch]$Remove
    )
    $src = $Config.tenants.source
    if (-not (Test-ExoConfigured $src)) { throw 'Source Exchange Online is not configured.' }

    $maps = @(Get-Mappings) | Where-Object { $_.matchState -eq 'matched' -and $_.targetUpn }
    if ($SourceUpns -and $SourceUpns.Count -gt 0) { $maps = @($maps | Where-Object { $SourceUpns -contains $_.sourceUpn }) }
    if (@($maps).Count -eq 0) { throw 'No matched users with a target address to forward.' }

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        Connect-TenantExo -Tenant $src
        Assert-CmdletReady -Name 'Set-Mailbox' -RequiredParameters @('Identity', 'ForwardingSmtpAddress', 'DeliverToMailboxAndForward')
        foreach ($m in $maps) {
            $corr = New-CorrelationId
            try {
                if ($Remove) {
                    Invoke-WithRetry -RunId $RunId -Action {
                        Set-Mailbox -Identity $m.sourceUpn -ForwardingSmtpAddress $null -ForwardingAddress $null -DeliverToMailboxAndForward $false -ErrorAction Stop
                    } | Out-Null
                    Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'mailbox.forwarding.clear' -Target $m.sourceUpn -Detail 'forwarding removed'
                    $results.Add(@{ sourceUpn = $m.sourceUpn; status = 'cleared' })
                }
                else {
                    Invoke-WithRetry -RunId $RunId -Action {
                        Set-Mailbox -Identity $m.sourceUpn -ForwardingSmtpAddress $m.targetUpn -DeliverToMailboxAndForward $KeepCopy -ErrorAction Stop
                    } | Out-Null
                    Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'mailbox.forwarding.set' -Target $m.sourceUpn -Detail "-> $($m.targetUpn) (keepCopy=$KeepCopy)"
                    $results.Add(@{ sourceUpn = $m.sourceUpn; status = 'set'; target = $m.targetUpn; keepCopy = $KeepCopy })
                }
            }
            catch { $results.Add(@{ sourceUpn = $m.sourceUpn; status = 'failed'; reason = $_.Exception.Message }) }
        }
    }
    finally { Disconnect-TenantExo }
    return @{ action = ($Remove ? 'remove' : 'set'); results = $results }
}

function Get-OutboundForwardingMode {
    <#
    .SYNOPSIS
        Reads the SOURCE tenant's outbound auto-forwarding policy (AutoForwardingMode). When this
        is 'Automatic' or 'Off', admin-set ForwardingSmtpAddress to external domains is dropped.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Config)
    $src = $Config.tenants.source
    if (-not (Test-ExoConfigured $src)) { throw 'Source Exchange Online is not configured.' }
    try {
        Connect-TenantExo -Tenant $src
        $p = Get-HostedOutboundSpamFilterPolicy -Identity Default
        return @{ autoForwardingMode = [string]$p.AutoForwardingMode }
    }
    finally { Disconnect-TenantExo }
}

function Set-OutboundForwardingMode {
    <#
    .SYNOPSIS
        Sets the SOURCE tenant outbound auto-forwarding policy. 'On' force-allows external
        forwarding (needed for cutover); 'Automatic' = service decides (usually blocks); 'Off' = blocked.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId,
        [ValidateSet('On', 'Automatic', 'Off')][string]$Mode = 'On')
    $src = $Config.tenants.source
    if (-not (Test-ExoConfigured $src)) { throw 'Source Exchange Online is not configured.' }
    try {
        Connect-TenantExo -Tenant $src
        Assert-CmdletReady -Name 'Set-HostedOutboundSpamFilterPolicy' -RequiredParameters @('Identity', 'AutoForwardingMode')
        Set-HostedOutboundSpamFilterPolicy -Identity Default -AutoForwardingMode $Mode -ErrorAction Stop | Out-Null
        Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action 'exo.outbound-forwarding.set' -Target 'Default' -Detail "AutoForwardingMode=$Mode"
        return @{ autoForwardingMode = $Mode }
    }
    finally { Disconnect-TenantExo }
}

# ---------------- COMPLETE (DESTRUCTIVE, gated) ----------------

function Complete-MailboxBatch {
    <#
    .SYNOPSIS
        DESTRUCTIVE: completes the batch, which DELETES the source mailboxes. Refused unless
        every item is Synced and ConfirmToken equals the batch name. Snapshots first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$BatchId,
        [Parameter(Mandatory)][string]$ConfirmToken
    )
    $b = Get-MailboxBatch -BatchId $BatchId
    if (-not $b) { throw 'Batch not found.' }
    if ($ConfirmToken -ne $b.name) { throw "Confirmation token does not match the batch name '$($b.name)'." }

    # Re-verify against live EXO immediately before finalizing.
    Update-MailboxBatchStatus -Config $Config -BatchId $BatchId | Out-Null
    $ready = Test-BatchReadyToComplete -BatchId $BatchId
    if (-not $ready.ready) { throw "Batch not ready to complete: $($ready.reason)" }

    # Snapshot BEFORE the destructive step (guardrail #3).
    $snapBatch = Get-MailboxBatch -BatchId $BatchId
    Write-MailboxSnapshot -RunId $RunId -Tag "mailbox-complete-$BatchId-$RunId" -Data $snapBatch

    $tgt = $Config.tenants.target
    try {
        Connect-TenantExo -Tenant $tgt
        Assert-CmdletReady -Name 'Complete-MigrationBatch' -RequiredParameters @('Identity')
        Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action 'mailbox.batch.complete.DESTRUCTIVE' -Target $b.exoBatchName -Detail 'Completing batch — source mailboxes will be deleted'
        Invoke-WithRetry -RunId $RunId -Action { Complete-MigrationBatch -Identity $b.exoBatchName -Confirm:$false -ErrorAction Stop } | Out-Null
    }
    finally { Disconnect-TenantExo }

    $now = [DateTime]::UtcNow.ToString('o')
    Invoke-DbQuery -Query 'UPDATE mailbox_batches SET status=''completing'', updated_utc=@t WHERE batch_id=@b;' -SqlParameters @{ t = $now; b = $BatchId } | Out-Null
    Invoke-DbQuery -Query 'UPDATE mailbox_batch_items SET status=''completing'', last_status_utc=@t WHERE batch_id=@b;' -SqlParameters @{ t = $now; b = $BatchId } | Out-Null
    Write-JsonLog -RunId $RunId -Level Warning -Message 'Batch completion requested (DESTRUCTIVE)' -Data @{ batchId = $BatchId; name = $b.name }
    return Get-MailboxBatch -BatchId $BatchId
}

Export-ModuleMember -Function `
    Get-MailboxBatches, Get-MailboxBatch, Test-BatchReadyToComplete, `
    New-MailboxBatch, Update-MailboxBatchStatus, Set-SourceForwarding, Set-MappingForwarding, `
    Get-OutboundForwardingMode, Set-OutboundForwardingMode, Complete-MailboxBatch

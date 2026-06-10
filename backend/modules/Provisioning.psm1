#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Target MailUser provisioning from selected source users (first MUTATING feature).
.DESCRIPTION
    For a set of selected source users, creates mail-enabled users (MailUsers) in the TARGET
    tenant carrying the source attributes but with a new UPN/primary address on a target
    domain, plus a temporary password (random-per-user or one shared value; force change at
    first sign-in). A MailUser is the object the cross-tenant mailbox MOVE expects, and what
    Phase 3 preflight checks for — so this does NOT create a target mailbox.

    Safety (project guardrails):
      - Read-only PREVIEW (Build-ProvisioningPlan) computes exactly what would happen with no
        mutation. The UI requires it before the gated execute.
      - Idempotent: a target UPN that already exists is SKIPPED (detected via Graph).
      - State snapshot to disk before any creation (guardrail #3).
      - Every creation is audited with a correlation id. Passwords are NEVER logged, never
        written to SQLite, and never snapshotted — they are returned once in-memory.

    GUARDRAIL #4: EXO New-MailUser / Set-User are REST cmdlets only materialized after
    Connect-ExchangeOnline, so their exact parameters could not be introspected offline.
    Verify them against a live tenant (Get-Command New-MailUser -Syntax) before first real
    run. Graph calls (Get-MgDomain, Get-MgUser existence, Update-MgUser passwordProfile)
    were verified against Microsoft.Graph 2.36.1.

    Depends on State.psm1, Logging.psm1 in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')

# Source attributes copied to the target MailUser.
$script:SourceProps = @(
    'id', 'userPrincipalName', 'displayName', 'givenName', 'surname', 'mail',
    'jobTitle', 'department', 'companyName', 'officeLocation', 'mobilePhone',
    'businessPhones', 'city', 'state', 'country', 'streetAddress', 'postalCode',
    'usageLocation', 'preferredLanguage'
)

function Test-GraphConfigured {
    param($Tenant)
    $g = $Tenant.graph
    return (($script:Placeholders -notcontains $g.appId) -and ($script:Placeholders -notcontains $g.certThumbprint) -and ($script:Placeholders -notcontains $Tenant.tenantId))
}
function Test-ExoConfigured {
    param($Tenant)
    $e = $Tenant.exchangeOnline
    return (($script:Placeholders -notcontains $e.appId) -and ($script:Placeholders -notcontains $e.certThumbprint) -and ($script:Placeholders -notcontains $e.organization))
}

function Connect-TenantGraph {
    param($Tenant)
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    Connect-MgGraph -ClientId $Tenant.graph.appId -TenantId $Tenant.tenantId -CertificateThumbprint $Tenant.graph.certThumbprint -NoWelcome -ErrorAction Stop
}
function Connect-TenantExo {
    param($Tenant)
    $e = $Tenant.exchangeOnline
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-ExchangeOnline -AppId $e.appId -Organization $e.organization -CertificateThumbprint $e.certThumbprint -ShowBanner:$false -ShowProgress:$false -ErrorAction Stop
}

function New-StrongPassword {
    param([int]$Length = 16)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digit = '23456789'; $symbol = '!@#$%^&*-_=+'
    $all = ($upper + $lower + $digit + $symbol).ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function pick($set) { $b = [byte[]]::new(1); $rng.GetBytes($b); $set[$b[0] % $set.Length] }
    $chars = @((pick $upper), (pick $lower), (pick $digit), (pick $symbol))
    for ($i = $chars.Count; $i -lt $Length; $i++) { $chars += pick $all }
    # Shuffle.
    $chars = $chars | Sort-Object { $b = [byte[]]::new(1); $rng.GetBytes($b); $b[0] }
    return -join $chars
}

function Get-TargetDomains {
    <#
    .SYNOPSIS
        Returns the target tenant's verified domains (for building new UPNs).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    $t = $Config.tenants.target
    if (-not (Test-GraphConfigured $t)) { throw 'Graph is not configured for the target tenant.' }
    try {
        Connect-TenantGraph -Tenant $t
        $domains = Get-MgDomain -All -ErrorAction Stop | Where-Object { $_.IsVerified }
        return @($domains | ForEach-Object { [ordered]@{ id = $_.Id; isDefault = [bool]$_.IsDefault } } | Sort-Object { -[int]$_.isDefault })
    }
    finally { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }
}

function Get-LocalPart { param([string]$Upn) return (($Upn -split '@', 2)[0]) }

function Build-ProvisioningPlan {
    <#
    .SYNOPSIS
        Read-only: builds the create plan for selected source users (no mutation).
    .PARAMETER Overrides
        Optional hashtable keyed by source UPN -> @{ newUpn = '...' } to override the derived UPN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string[]]$SourceUpns,
        [Parameter(Mandatory)] [string]$TargetDomain,
        [hashtable]$Overrides = @{}
    )
    $src = $Config.tenants.source
    $tgt = $Config.tenants.target
    if (-not (Test-GraphConfigured $src)) { throw 'Graph is not configured for the source tenant.' }
    if (-not (Test-GraphConfigured $tgt)) { throw 'Graph is not configured for the target tenant.' }

    # 1. Pull full source attributes for the selected users.
    $details = @{}
    try {
        Connect-TenantGraph -Tenant $src
        foreach ($upn in $SourceUpns) {
            try { $details[$upn] = Get-MgUser -UserId $upn -Property ($script:SourceProps -join ',') -ErrorAction Stop }
            catch { $details[$upn] = $null }
        }
    }
    finally { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }

    # 2. Check target existence (idempotency) against target Graph.
    $existing = @{}
    try {
        Connect-TenantGraph -Tenant $tgt
        foreach ($upn in $SourceUpns) {
            $newUpn = if ($Overrides[$upn].newUpn) { $Overrides[$upn].newUpn } else { '{0}@{1}' -f (Get-LocalPart $upn), $TargetDomain }
            try { $existing[$newUpn] = [bool](Get-MgUser -UserId $newUpn -Property id -ErrorAction Stop) }
            catch { $existing[$newUpn] = $false }
        }
    }
    finally { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }

    # 3. Compose plan rows.
    $plan = foreach ($upn in $SourceUpns) {
        $d = $details[$upn]
        $newUpn = if ($Overrides[$upn].newUpn) { $Overrides[$upn].newUpn } else { '{0}@{1}' -f (Get-LocalPart $upn), $TargetDomain }
        [ordered]@{
            sourceUpn            = $upn
            sourceDisplayName    = $d.DisplayName
            found                = [bool]$d
            newUpn               = $newUpn
            newPrimaryAddress    = $newUpn
            externalEmailAddress = ($d.Mail ?? $upn)
            targetExists         = [bool]$existing[$newUpn]
            willSkip             = ([bool]$existing[$newUpn] -or -not $d)
            attributes           = if ($d) {
                [ordered]@{
                    displayName = $d.DisplayName; givenName = $d.GivenName; surname = $d.Surname
                    jobTitle = $d.JobTitle; department = $d.Department; companyName = $d.CompanyName
                    officeLocation = $d.OfficeLocation; usageLocation = $d.UsageLocation
                }
            } else { $null }
        }
    }
    return @($plan)
}

function Invoke-Provisioning {
    <#
    .SYNOPSIS
        GATED MUTATION: creates target MailUsers per the plan. Returns results incl. the
        one-time passwords (in-memory only). Idempotent; snapshots before mutating.
    .PARAMETER PasswordMode
        'random' (unique per user) or 'shared' (use SharedPassword for all).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$RunId,
        [Parameter(Mandatory)] [string[]]$SourceUpns,
        [Parameter(Mandatory)] [string]$TargetDomain,
        [ValidateSet('random', 'shared')] [string]$PasswordMode = 'random',
        [string]$SharedPassword,
        [bool]$ForceChange = $true,
        [bool]$AddToGroups = $false,
        [hashtable]$Overrides = @{}
    )

    $tgt = $Config.tenants.target
    if (-not (Test-ExoConfigured $tgt)) { throw 'Exchange Online is not configured for the target tenant (required to create MailUsers).' }
    if (-not (Test-GraphConfigured $tgt)) { throw 'Graph is not configured for the target tenant.' }
    if ($PasswordMode -eq 'shared' -and [string]::IsNullOrWhiteSpace($SharedPassword)) { throw 'Shared password mode selected but no password provided.' }

    $plan = Build-ProvisioningPlan -Config $Config -SourceUpns $SourceUpns -TargetDomain $TargetDomain -Overrides $Overrides

    # Snapshot BEFORE mutating (no passwords in the snapshot).
    $snapDir = Join-Path (Split-Path $env:MIG_DB_PATH -Parent) 'snapshots'
    if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
    $snapshot = $plan | ForEach-Object { [ordered]@{ sourceUpn = $_.sourceUpn; newUpn = $_.newUpn; targetExists = $_.targetExists; willSkip = $_.willSkip } }
    ($snapshot | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $snapDir "provisioning-$RunId.json") -Encoding utf8

    $results = [System.Collections.Generic.List[object]]::new()
    $now = [DateTime]::UtcNow.ToString('o')

    try {
        Connect-TenantExo -Tenant $tgt
        Connect-TenantGraph -Tenant $tgt

        foreach ($row in $plan) {
            $corr = New-CorrelationId
            $res = [ordered]@{ sourceUpn = $row.sourceUpn; targetUpn = $row.newUpn; status = $null; reason = $null; password = $null }

            if ($row.willSkip) {
                $res.status = 'skipped'
                $res.reason = if ($row.targetExists) { 'Target UPN already exists' } else { 'Source user not found' }
            }
            else {
                $pw = if ($Overrides[$row.sourceUpn].password) { $Overrides[$row.sourceUpn].password }
                      elseif ($PasswordMode -eq 'shared') { $SharedPassword }
                      else { New-StrongPassword }
                try {
                    $secure = ConvertTo-SecureString $pw -AsPlainText -Force
                    $a = $row.attributes
                    # GUARDRAIL #4: verify these params live before first real run.
                    New-MailUser -Name $row.newUpn -MicrosoftOnlineServicesID $row.newUpn -Password $secure `
                        -DisplayName $a.displayName -FirstName $a.givenName -LastName $a.surname `
                        -ExternalEmailAddress $row.externalEmailAddress -ErrorAction Stop | Out-Null

                    # Best-effort attribute copy (failures don't fail the create).
                    $setUser = @{}
                    if ($a.jobTitle) { $setUser.Title = $a.jobTitle }
                    if ($a.department) { $setUser.Department = $a.department }
                    if ($a.companyName) { $setUser.Company = $a.companyName }
                    if ($a.officeLocation) { $setUser.Office = $a.officeLocation }
                    if ($setUser.Count -gt 0) {
                        try { Set-User -Identity $row.newUpn @setUser -ErrorAction Stop | Out-Null } catch { }
                    }
                    if ($a.usageLocation) {
                        try { Update-MgUser -UserId $row.newUpn -UsageLocation $a.usageLocation -ErrorAction Stop } catch { }
                    }
                    if ($ForceChange) {
                        try { Update-MgUser -UserId $row.newUpn -PasswordProfile @{ ForceChangePasswordNextSignIn = $true } -ErrorAction Stop } catch { }
                    }

                    $res.status = 'created'
                    $res.password = $pw

                    # Optional: add the new user to mapped target groups (Phase 9).
                    if ($AddToGroups) {
                        try {
                            Import-Module Microsoft.Graph.Groups -ErrorAction Stop
                            $newId = (Get-MgUser -UserId $row.newUpn -Property id -ErrorAction Stop).Id
                            $tg = Invoke-DbQuery -Query @'
SELECT g.target_group_id FROM group_members gm
JOIN groups g ON gm.group_id = g.group_id
WHERE lower(gm.member_upn) = lower(@u) AND g.target_group_id IS NOT NULL;
'@ -SqlParameters @{ u = $row.sourceUpn }
                            foreach ($grp in @($tg)) {
                                try { New-MgGroupMember -GroupId $grp.target_group_id -DirectoryObjectId $newId -ErrorAction Stop } catch { }
                            }
                        }
                        catch { }
                    }
                }
                catch {
                    $res.status = 'failed'
                    $res.reason = $_.Exception.Message
                }
            }

            # Audit + persist WITHOUT the password.
            Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'provisioning.mailuser.create' `
                -Target $row.newUpn -Detail "status=$($res.status); source=$($row.sourceUpn)"
            Invoke-DbQuery -Query @'
INSERT INTO provisioning_results (run_id, source_upn, target_upn, status, reason, created_utc)
VALUES (@run, @src, @tgt, @status, @reason, @t);
'@ -SqlParameters @{ run = $RunId; src = $row.sourceUpn; tgt = $row.newUpn; status = $res.status; reason = $res.reason; t = $now } | Out-Null

            $results.Add($res)
        }
    }
    finally {
        try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    $created = @($results | Where-Object { $_.status -eq 'created' }).Count
    $skipped = @($results | Where-Object { $_.status -eq 'skipped' }).Count
    $failed = @($results | Where-Object { $_.status -eq 'failed' }).Count
    Invoke-DbQuery -Query @'
INSERT INTO provisioning_runs (run_id, created_utc, target_domain, created_count, skipped_count, failed_count)
VALUES (@id, @t, @dom, @c, @s, @f);
'@ -SqlParameters @{ id = $RunId; t = $now; dom = $TargetDomain; c = $created; s = $skipped; f = $failed } | Out-Null

    return [ordered]@{
        runId   = $RunId
        created = $created; skipped = $skipped; failed = $failed
        results = $results   # includes one-time passwords for created users
    }
}

function Get-ProvisioningRun {
    [CmdletBinding()]
    param([string]$RunId)
    if (-not $RunId) {
        $first = @(Invoke-DbQuery -Query 'SELECT run_id FROM provisioning_runs ORDER BY created_utc DESC LIMIT 1;') | Select-Object -First 1
        if ($first) { $RunId = $first.run_id }
    }
    if (-not $RunId) { return $null }
    $run = @(Invoke-DbQuery -Query 'SELECT * FROM provisioning_runs WHERE run_id = @id;' -SqlParameters @{ id = $RunId }) | Select-Object -First 1
    $rows = Invoke-DbQuery -Query 'SELECT source_upn, target_upn, status, reason FROM provisioning_results WHERE run_id = @id ORDER BY status, source_upn;' -SqlParameters @{ id = $RunId }
    return [ordered]@{
        runId = $RunId; createdUtc = $run.created_utc; targetDomain = $run.target_domain
        created = $run.created_count; skipped = $run.skipped_count; failed = $run.failed_count
        results = @($rows) | ForEach-Object { [ordered]@{ sourceUpn = $_.source_upn; targetUpn = $_.target_upn; status = $_.status; reason = $_.reason } }
    }
}

Export-ModuleMember -Function Get-TargetDomains, Build-ProvisioningPlan, Invoke-Provisioning, Get-ProvisioningRun

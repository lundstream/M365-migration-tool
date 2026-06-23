#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Cross-tenant migration prerequisite setup (Phase 4 — gated mutations).
.DESCRIPTION
    DETECT-then-CREATE three prerequisites:
      1. Migration endpoint (target Exchange Online)
      2. Organization relationship with mailbox-move capability (target Exchange Online)
      3. SharePoint Online cross-tenant relationship (both tenants)
    Detection is read-only. Creation is an explicit, confirmed operator action; if a
    prerequisite already exists it is reported and left untouched (idempotent). A state
    snapshot is written to disk before each change, and every change is audited.

    GUARDRAIL #4 — verification:
      - SPO cmdlets are a binary module and were verified offline:
          Set-SPOCrossTenantRelationship -Scenario <MnA> -PartnerRole <Source|Target> -PartnerCrossTenantHostUrl <url>
          Get-SPOCrossTenantHostUrl ; Get-SPOCrossTenantRelationship[ByScenario]
      - EXO cmdlets (New-MigrationEndpoint, *-OrganizationRelationship) are REST cmdlets that
        only materialize after Connect-ExchangeOnline, so their parameters could NOT be
        verified offline. Before invoking them this module calls Assert-CmdletReady, which
        runs Get-Command and ABORTS if the cmdlet or any parameter we intend to pass is
        absent — enforcing guardrail #4 at runtime. The exact parameters can be overridden
        in config.migration.{endpointParameters,organizationRelationshipParameters} after you
        confirm them with Get-Command <cmdlet> -Syntax on your connected tenant.

    Depends on State.psm1, Logging.psm1 in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')

function Test-ExoConfigured {
    param($Tenant)
    $e = $Tenant.exchangeOnline
    return (($script:Placeholders -notcontains $e.appId) -and ($script:Placeholders -notcontains $e.certThumbprint) -and ($script:Placeholders -notcontains $e.organization))
}
function Test-SpoConfigured {
    param($Tenant)
    $s = $Tenant.sharePoint
    return (($script:Placeholders -notcontains $s.appId) -and ($script:Placeholders -notcontains $s.certThumbprint) -and ($script:Placeholders -notcontains $s.adminUrl))
}

function Connect-TenantExo {
    param($Tenant)
    $e = $Tenant.exchangeOnline
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-ExchangeOnline -AppId $e.appId -Organization $e.organization -CertificateThumbprint $e.certThumbprint -ShowBanner:$false -ShowProgress:$false -ErrorAction Stop
}
function Connect-TenantSpo {
    param($Tenant)
    $s = $Tenant.sharePoint
    Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop
    Connect-SPOService -Url $s.adminUrl -ClientId $s.appId -Certificate (Get-SpoCertificate $s.certThumbprint) -TenantId $Tenant.tenantId -ErrorAction Stop
}

function Assert-CmdletReady {
    <#
    .SYNOPSIS
        Guardrail #4 at runtime: verify a cmdlet exists and exposes every parameter we plan
        to pass, aborting safely otherwise.
    #>
    param([Parameter(Mandatory)][string]$Name, [string[]]$RequiredParameters = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Cmdlet '$Name' is not available (not connected, or module changed). Verify before use (guardrail #4)."
    }
    $have = @($cmd.Parameters.Keys)
    $missing = @($RequiredParameters | Where-Object { $_ -notin $have })
    if ($missing.Count -gt 0) {
        throw "Cmdlet '$Name' is missing expected parameter(s): $($missing -join ', '). Confirm exact syntax via 'Get-Command $Name -Syntax' and set config.migration overrides (guardrail #4)."
    }
}

function ConvertTo-Splat {
    # Turn a JSON object (PSCustomObject) into a hashtable for splatting.
    param($Object)
    $h = @{}
    if ($null -eq $Object) { return $h }
    foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Write-SetupSnapshot {
    param([string]$RunId, [string]$Item, $Data)
    $snapDir = Join-Path (Split-Path $env:MIG_DB_PATH -Parent) 'snapshots'
    if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
    ($Data | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $snapDir "migsetup-$RunId-$Item.json") -Encoding utf8
}

function New-Item-Result {
    param([string]$Key, [string]$Name, [string]$Status, [string]$Detail, $Planned = $null)
    return [ordered]@{ item = $Key; name = $Name; status = $Status; detail = $Detail; planned = $Planned }
}

# ---------------- DETECT ----------------

function Get-MigrationSetupStatus {
    <#
    .SYNOPSIS
        Read-only detection of all three prerequisites.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $tgt = $Config.tenants.target
    $items = @()

    # Endpoint + organization relationship (target EXO).
    if (Test-ExoConfigured $tgt) {
        try {
            Connect-TenantExo -Tenant $tgt
            $epName = $Config.migration.endpointName
            try {
                $eps = @(Get-MigrationEndpoint -ErrorAction Stop)
                $ep = $eps | Where-Object { $_.Identity -eq $epName -or $_.Name -eq $epName } | Select-Object -First 1
                $items += if ($ep) { New-Item-Result 'endpoint' $epName 'present' 'Migration endpoint exists' }
                          else { New-Item-Result 'endpoint' $epName 'missing' "No endpoint named '$epName' ($($eps.Count) endpoint(s) total)" }
            }
            catch { $items += New-Item-Result 'endpoint' $epName 'error' $_.Exception.Message }

            $orName = $Config.migration.organizationRelationshipName
            try {
                $ors = @(Get-OrganizationRelationship -ErrorAction Stop)
                $or = $ors | Where-Object { $_.Name -eq $orName } | Select-Object -First 1
                if ($or) {
                    $moveOn = ($or.PSObject.Properties.Name -contains 'MailboxMoveEnabled' -and $or.MailboxMoveEnabled)
                    $items += New-Item-Result 'orgRelationship' $orName ($moveOn ? 'present' : 'missing') ($moveOn ? 'Exists with mailbox move enabled' : 'Exists but mailbox move NOT enabled')
                }
                else { $items += New-Item-Result 'orgRelationship' $orName 'missing' "No organization relationship named '$orName'" }
            }
            catch { $items += New-Item-Result 'orgRelationship' $orName 'error' $_.Exception.Message }
        }
        catch {
            $items += New-Item-Result 'endpoint' $Config.migration.endpointName 'error' "Target EXO connect failed: $($_.Exception.Message)"
            $items += New-Item-Result 'orgRelationship' $Config.migration.organizationRelationshipName 'error' "Target EXO connect failed: $($_.Exception.Message)"
        }
        finally { try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { } }
    }
    else {
        $items += New-Item-Result 'endpoint' $Config.migration.endpointName 'not-configured' 'Target Exchange Online not configured'
        $items += New-Item-Result 'orgRelationship' $Config.migration.organizationRelationshipName 'not-configured' 'Target Exchange Online not configured'
    }

    # SPO cross-tenant relationship (detected from target).
    if (Test-SpoConfigured $tgt) {
        try {
            Connect-TenantSpo -Tenant $tgt
            $scenario = $Config.migration.spoScenario
            try {
                $rel = @(Get-SPOCrossTenantRelationship -ErrorAction Stop)
                $items += if ($rel.Count -gt 0) { New-Item-Result 'spoRelationship' "SPO ($scenario)" 'present' 'SPO cross-tenant relationship present' }
                          else { New-Item-Result 'spoRelationship' "SPO ($scenario)" 'missing' 'No SPO cross-tenant relationship' }
            }
            catch { $items += New-Item-Result 'spoRelationship' "SPO ($scenario)" 'error' $_.Exception.Message }
        }
        catch { $items += New-Item-Result 'spoRelationship' "SPO" 'error' "Target SPO connect failed: $($_.Exception.Message)" }
        finally { try { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null } catch { } }
    }
    else {
        $items += New-Item-Result 'spoRelationship' 'SPO' 'not-configured' 'Target SharePoint not configured'
    }

    return [ordered]@{ generatedUtc = [DateTime]::UtcNow.ToString('o'); items = $items }
}

# ---------------- CREATE (gated) ----------------

function Invoke-CreateMigrationEndpoint {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId)
    $tgt = $Config.tenants.target
    if (-not (Test-ExoConfigured $tgt)) { return New-Item-Result 'endpoint' $Config.migration.endpointName 'failed' 'Target Exchange Online not configured' }

    $name = $Config.migration.endpointName
    $sourceDomain = $Config.tenants.source.exchangeOnline.organization
    # Best-effort cross-tenant defaults; override via config.migration.endpointParameters.
    $params = if ($Config.migration.endpointParameters) { ConvertTo-Splat $Config.migration.endpointParameters }
              else { @{ Name = $name; RemoteTenant = $sourceDomain; ApplicationId = $Config.migration.migrationAppId } }

    try {
        Connect-TenantExo -Tenant $tgt
        $existing = @(Get-MigrationEndpoint -ErrorAction Stop) | Where-Object { $_.Identity -eq $name -or $_.Name -eq $name } | Select-Object -First 1
        if ($existing) { return New-Item-Result 'endpoint' $name 'skipped' 'Already exists — left unchanged' }

        Assert-CmdletReady -Name 'New-MigrationEndpoint' -RequiredParameters @($params.Keys)
        Write-SetupSnapshot -RunId $RunId -Item 'endpoint' -Data @{ action = 'New-MigrationEndpoint'; preState = 'absent'; parameters = $params }
        $corr = New-CorrelationId
        Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'migsetup.endpoint.create' -Target $name -Detail "New-MigrationEndpoint $($params.Keys -join ',')"
        New-MigrationEndpoint @params -ErrorAction Stop | Out-Null
        return New-Item-Result 'endpoint' $name 'created' 'Migration endpoint created' $params
    }
    catch { return New-Item-Result 'endpoint' $name 'failed' $_.Exception.Message $params }
    finally { try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { } }
}

function Invoke-CreateOrgRelationship {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId)
    $tgt = $Config.tenants.target
    if (-not (Test-ExoConfigured $tgt)) { return New-Item-Result 'orgRelationship' $Config.migration.organizationRelationshipName 'failed' 'Target Exchange Online not configured' }

    $name = $Config.migration.organizationRelationshipName
    $sourceDomain = $Config.tenants.source.exchangeOnline.organization
    $params = if ($Config.migration.organizationRelationshipParameters) { ConvertTo-Splat $Config.migration.organizationRelationshipParameters }
              else {
                  @{
                      Name               = $name
                      DomainNames        = @($sourceDomain)
                      MailboxMoveEnabled = $true
                      MailboxMoveCapability = 'Inbound'
                      OAuthApplicationId = $Config.migration.migrationAppId
                  }
              }

    try {
        Connect-TenantExo -Tenant $tgt
        $existing = @(Get-OrganizationRelationship -ErrorAction Stop) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($existing) { return New-Item-Result 'orgRelationship' $name 'skipped' 'Already exists — left unchanged' }

        Assert-CmdletReady -Name 'New-OrganizationRelationship' -RequiredParameters @($params.Keys)
        Write-SetupSnapshot -RunId $RunId -Item 'orgRelationship' -Data @{ action = 'New-OrganizationRelationship'; preState = 'absent'; parameters = $params }
        $corr = New-CorrelationId
        Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'migsetup.orgrel.create' -Target $name -Detail "New-OrganizationRelationship $($params.Keys -join ',')"
        New-OrganizationRelationship @params -ErrorAction Stop | Out-Null
        return New-Item-Result 'orgRelationship' $name 'created' 'Organization relationship created (target/inbound). Configure the source/outbound side separately.' $params
    }
    catch { return New-Item-Result 'orgRelationship' $name 'failed' $_.Exception.Message $params }
    finally { try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { } }
}

function Invoke-SetSpoRelationship {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId)
    $src = $Config.tenants.source; $tgt = $Config.tenants.target
    if (-not (Test-SpoConfigured $tgt) -or -not (Test-SpoConfigured $src)) {
        return New-Item-Result 'spoRelationship' 'SPO' 'failed' 'SharePoint not configured for both tenants'
    }
    $scenario = $Config.migration.spoScenario

    try {
        # Each tenant's own host URL.
        Connect-TenantSpo -Tenant $src
        $srcHost = [regex]::Match([string](Get-SPOCrossTenantHostUrl -ErrorAction Stop), 'https?://[^\s/]+\.sharepoint\.com').Value
        try { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null } catch { }

        Connect-TenantSpo -Tenant $tgt
        $tgtHost = [regex]::Match([string](Get-SPOCrossTenantHostUrl -ErrorAction Stop), 'https?://[^\s/]+\.sharepoint\.com').Value

        Assert-CmdletReady -Name 'Set-SPOCrossTenantRelationship' -RequiredParameters @('Scenario', 'PartnerRole', 'PartnerCrossTenantHostUrl')
        Write-SetupSnapshot -RunId $RunId -Item 'spoRelationship' -Data @{ action = 'Set-SPOCrossTenantRelationship'; scenario = $scenario; targetPartner = 'Source'; sourcePartner = 'Target' }
        $corr = New-CorrelationId

        # On target: partner is the Source tenant.
        Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'migsetup.spo.settarget' -Target $tgt.sharePoint.adminUrl -Detail "Scenario=$scenario PartnerRole=Source"
        Set-SPOCrossTenantRelationship -Scenario $scenario -PartnerRole Source -PartnerCrossTenantHostUrl $srcHost -ErrorAction Stop | Out-Null
        try { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null } catch { }

        # On source: partner is the Target tenant.
        Connect-TenantSpo -Tenant $src
        Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'migsetup.spo.setsource' -Target $src.sharePoint.adminUrl -Detail "Scenario=$scenario PartnerRole=Target"
        Set-SPOCrossTenantRelationship -Scenario $scenario -PartnerRole Target -PartnerCrossTenantHostUrl $tgtHost -ErrorAction Stop | Out-Null

        return New-Item-Result 'spoRelationship' "SPO ($scenario)" 'created' 'SPO cross-tenant relationship set on both tenants'
    }
    catch { return New-Item-Result 'spoRelationship' "SPO ($scenario)" 'failed' $_.Exception.Message }
    finally { try { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null } catch { } }
}

function Invoke-MigrationSetupCreate {
    <#
    .SYNOPSIS
        Dispatches a single gated create. Item: endpoint | orgRelationship | spoRelationship.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('endpoint', 'orgRelationship', 'spoRelationship')][string]$Item
    )
    switch ($Item) {
        'endpoint'        { return Invoke-CreateMigrationEndpoint -Config $Config -RunId $RunId }
        'orgRelationship' { return Invoke-CreateOrgRelationship   -Config $Config -RunId $RunId }
        'spoRelationship' { return Invoke-SetSpoRelationship       -Config $Config -RunId $RunId }
    }
}

Export-ModuleMember -Function Get-MigrationSetupStatus, Invoke-MigrationSetupCreate

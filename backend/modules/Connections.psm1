#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Read-only connection manager for the M365 migration tool (Phase 1).
.DESCRIPTION
    App-only certificate authentication to Microsoft Graph, Exchange Online, and the
    SharePoint Online admin endpoint for BOTH source and target tenants, plus a
    connection-health probe that reports per tenant / per service whether the connection
    succeeds and which identity is in use.

    No mutations anywhere. Heavy M365 modules are imported lazily inside each probe and
    only when a service is actually configured, so an unconfigured install stays fast.
    Secrets (cert private keys) live in the Windows cert store; only thumbprints are
    referenced and they are NEVER written to logs.

    Cmdlet signatures verified against installed modules (2026-06):
      Connect-MgGraph        -ClientId -TenantId -CertificateThumbprint -NoWelcome
      Connect-ExchangeOnline -AppId -Organization -CertificateThumbprint -ShowBanner -ShowProgress
      Connect-SPOService     -Url -ClientId -CertificateThumbprint -TenantId
    Per guardrail #4, re-verify before any *mutating* use in later phases.
#>

$script:Placeholders = @(
    $null, '',
    '00000000-0000-0000-0000-000000000000',
    'REPLACE_WITH_CERT_THUMBPRINT'
)

function Test-FieldConfigured {
    param([string]$Value)
    return ($Value -and ($script:Placeholders -notcontains $Value))
}

function Get-SpoCertificate {
    <#
    .SYNOPSIS
        Loads a certificate from the store by thumbprint as an X509Certificate2 object.
    .DESCRIPTION
        Connect-SPOService -CertificateThumbprint has a broken store lookup ("No certificate
        was found matching the specified parameters") even when the cert is present; passing
        the certificate object via -Certificate works. This loads it (CurrentUser first, then
        LocalMachine) for that purpose. Shared by all SPO connect paths.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Thumbprint)
    foreach ($loc in 'CurrentUser', 'LocalMachine') {
        $c = Get-Item "Cert:\$loc\My\$Thumbprint" -ErrorAction SilentlyContinue
        if ($c) { return $c }
    }
    throw "Certificate '$Thumbprint' not found in CurrentUser\My or LocalMachine\My."
}

function New-ServiceResult {
    param(
        [Parameter(Mandatory)][string]$Service,
        [bool]$Configured = $false,
        [bool]$Connected = $false,
        [string]$Identity,
        [string]$Detail,
        [string]$Error,
        [int]$DurationMs = 0
    )
    $status =
        if (-not $Configured) { 'not-configured' }
        elseif ($Connected)   { 'connected' }
        else                  { 'error' }

    return [ordered]@{
        service    = $Service
        status     = $status
        configured = $Configured
        connected  = $Connected
        identity   = $Identity
        detail     = $Detail
        error      = $Error
        durationMs = $DurationMs
    }
}

function Test-GraphConnection {
    <#
    .SYNOPSIS
        App-only cert connect to Microsoft Graph; report identity; disconnect.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Tenant)

    $g = $Tenant.graph
    if (-not ((Test-FieldConfigured $g.appId) -and (Test-FieldConfigured $g.certThumbprint) -and (Test-FieldConfigured $Tenant.tenantId))) {
        return New-ServiceResult -Service 'Graph'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Connect-MgGraph -ClientId $g.appId -TenantId $Tenant.tenantId -CertificateThumbprint $g.certThumbprint -NoWelcome -ErrorAction Stop
        $ctx = Get-MgContext
        $identity = if ($ctx.AppName) { "$($ctx.AppName) ($($ctx.ClientId))" } else { $ctx.ClientId }
        return New-ServiceResult -Service 'Graph' -Configured $true -Connected $true `
            -Identity $identity -Detail "auth=$($ctx.AuthType)" -DurationMs $sw.ElapsedMilliseconds
    }
    catch {
        return New-ServiceResult -Service 'Graph' -Configured $true -Connected $false `
            -Error $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
    }
    finally {
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
}

function Test-ExoConnection {
    <#
    .SYNOPSIS
        App-only cert connect to Exchange Online; report identity; disconnect.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Tenant)

    $e = $Tenant.exchangeOnline
    if (-not ((Test-FieldConfigured $e.appId) -and (Test-FieldConfigured $e.certThumbprint) -and (Test-FieldConfigured $e.organization))) {
        return New-ServiceResult -Service 'ExchangeOnline'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
        Connect-ExchangeOnline -AppId $e.appId -Organization $e.organization `
            -CertificateThumbprint $e.certThumbprint -ShowBanner:$false -ShowProgress:$false -ErrorAction Stop
        $ci = Get-ConnectionInformation | Where-Object { $_.Organization -eq $e.organization } | Select-Object -First 1
        if (-not $ci) { $ci = Get-ConnectionInformation | Select-Object -First 1 }
        $identity = if ($ci) { ($ci.UserPrincipalName ?? $ci.AppId) } else { $e.appId }
        return New-ServiceResult -Service 'ExchangeOnline' -Configured $true -Connected $true `
            -Identity $identity -Detail "org=$($e.organization)" -DurationMs $sw.ElapsedMilliseconds
    }
    catch {
        return New-ServiceResult -Service 'ExchangeOnline' -Configured $true -Connected $false `
            -Error $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
    }
    finally {
        try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
}

function Test-SpoConnection {
    <#
    .SYNOPSIS
        App-only cert connect to the SharePoint Online admin endpoint; disconnect.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Tenant)

    $s = $Tenant.sharePoint
    if (-not ((Test-FieldConfigured $s.appId) -and (Test-FieldConfigured $s.certThumbprint) -and (Test-FieldConfigured $s.adminUrl))) {
        return New-ServiceResult -Service 'SharePoint'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop
        Connect-SPOService -Url $s.adminUrl -ClientId $s.appId -Certificate (Get-SpoCertificate $s.certThumbprint) -TenantId $Tenant.tenantId -ErrorAction Stop
        # Read-only connectivity proof.
        $tenantInfo = Get-SPOTenant -ErrorAction Stop
        $detail = if ($tenantInfo) { "admin=$($s.adminUrl)" } else { $null }
        return New-ServiceResult -Service 'SharePoint' -Configured $true -Connected $true `
            -Identity $s.appId -Detail $detail -DurationMs $sw.ElapsedMilliseconds
    }
    catch {
        return New-ServiceResult -Service 'SharePoint' -Configured $true -Connected $false `
            -Error $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
    }
    finally {
        try { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
}

function Get-ConnectionHealth {
    <#
    .SYNOPSIS
        Probes Graph / EXO / SPO for both tenants and returns a normalized status model.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $tenants = @()
    foreach ($which in 'source', 'target') {
        $tenant = $Config.tenants.$which
        $services = @(
            (Test-GraphConnection -Tenant $tenant),
            (Test-ExoConnection   -Tenant $tenant),
            (Test-SpoConnection   -Tenant $tenant)
        )
        $tenants += [ordered]@{
            tenant      = $which
            displayName = $tenant.displayName
            tenantId    = $tenant.tenantId
            services    = $services
        }
    }
    return [ordered]@{
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        tenants      = $tenants
    }
}

function Get-ConnectionConfigSafe {
    <#
    .SYNOPSIS
        Returns the connection config with secrets redacted (thumbprints -> hasThumbprint).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    function Convert-Svc($svc) {
        if (-not $svc) { return $null }
        $o = [ordered]@{}
        foreach ($p in $svc.PSObject.Properties) {
            if ($p.Name -eq 'certThumbprint') {
                $o['hasThumbprint'] = (Test-FieldConfigured $p.Value)
            }
            else { $o[$p.Name] = $p.Value }
        }
        return $o
    }

    $tenants = [ordered]@{}
    foreach ($which in 'source', 'target') {
        $t = $Config.tenants.$which
        $tenants[$which] = [ordered]@{
            displayName    = $t.displayName
            tenantId       = $t.tenantId
            graph          = (Convert-Svc $t.graph)
            exchangeOnline = (Convert-Svc $t.exchangeOnline)
            sharePoint     = (Convert-Svc $t.sharePoint)
        }
    }
    return [ordered]@{ tenants = $tenants }
}

function Save-ConnectionConfig {
    <#
    .SYNOPSIS
        Persists NON-SECRET connection fields to config/config.json (creates it if absent).
    .DESCRIPTION
        Merges incoming non-secret fields (display names, tenant/app ids, organization,
        admin urls, and optionally a thumbprint reference) into config.json. Never accepts
        or stores private keys / secrets. Returns the redacted config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] $Update   # parsed JSON object matching tenants.{source,target}
    )

    $config =
        if (Test-Path -LiteralPath $ConfigPath) {
            Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        }
        else {
            $example = Join-Path (Split-Path $ConfigPath -Parent) 'config.example.json'
            Get-Content -LiteralPath $example -Raw | ConvertFrom-Json
        }

    $allowed = @{
        root           = @('displayName', 'tenantId')
        graph          = @('appId', 'certThumbprint')
        exchangeOnline = @('appId', 'organization', 'certThumbprint')
        sharePoint     = @('appId', 'adminUrl', 'certThumbprint')
    }

    foreach ($which in 'source', 'target') {
        if (-not $Update.tenants.$which) { continue }
        $src = $Update.tenants.$which
        $dst = $config.tenants.$which

        foreach ($f in $allowed.root) {
            if ($null -ne $src.$f) { $dst.$f = $src.$f }
        }
        foreach ($svc in 'graph', 'exchangeOnline', 'sharePoint') {
            if (-not $src.$svc) { continue }
            foreach ($f in $allowed.$svc) {
                if ($null -ne $src.$svc.$f) { $dst.$svc.$f = $src.$svc.$f }
            }
        }
    }

    ($config | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding utf8
    return (Get-ConnectionConfigSafe -Config $config)
}

Export-ModuleMember -Function `
    Test-GraphConnection, Test-ExoConnection, Test-SpoConnection, `
    Get-ConnectionHealth, Get-ConnectionConfigSafe, Save-ConnectionConfig, Get-SpoCertificate

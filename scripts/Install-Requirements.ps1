#requires -Version 7.0
<#
.SYNOPSIS
    Installs/verifies the PowerShell modules the backend needs (CurrentUser scope).
.DESCRIPTION
    Phase 0 only strictly requires Pode (HTTP host) and PSSQLite (state). The M365
    service modules (ExchangeOnlineManagement, Microsoft.Graph, PnP.PowerShell, and the
    SharePoint Online Management Shell) are reported here and installed in their phases.
    Run with: pwsh -File scripts/Install-Requirements.ps1
#>
[CmdletBinding()]
param(
    [switch]$IncludeServiceModules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

$required = @('Pode', 'PSSQLite')
if ($IncludeServiceModules) {
    # Targeted Graph sub-modules instead of the full Microsoft.Graph meta-module:
    # Authentication (Connect-MgGraph/Get-MgContext) + Users + Identity.DirectoryManagement
    # (subscribed SKUs for the Cross Tenant add-on check). Much faster to install/import.
    $required += @(
        'ExchangeOnlineManagement',
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Users',
        'Microsoft.Graph.Identity.DirectoryManagement',
        'PnP.PowerShell'
    )
}

foreach ($m in $required) {
    $have = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
    if ($have) {
        Write-Host ("[ok]   {0} {1}" -f $m, $have.Version) -ForegroundColor Green
    }
    else {
        Write-Host ("[..]   installing {0} ..." -f $m) -ForegroundColor Yellow
        Install-Module $m -Scope CurrentUser -Force -Repository PSGallery
        $have = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
        Write-Host ("[ok]   {0} {1}" -f $m, $have.Version) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Note: the SharePoint Online Management Shell (Microsoft.Online.SharePoint.PowerShell)' -ForegroundColor DarkGray
Write-Host 'is handled by scripts/Test-SpoHosting.ps1 — see README.md for the hosting decision.' -ForegroundColor DarkGray

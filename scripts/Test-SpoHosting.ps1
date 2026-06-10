#requires -Version 5.1
<#
.SYNOPSIS
    Phase 0 RISK SPIKE — resolve how to host the SharePoint Online cross-tenant cmdlets.
.DESCRIPTION
    BRIEF.md section 4: the SharePoint Online Management Shell
    (Microsoft.Online.SharePoint.PowerShell) has historically been Windows PowerShell
    5.1-only and may not import inside PS7, where Pode + ExchangeOnlineManagement run.

    This script gathers MACHINE-VERIFIED evidence rather than relying on training data:
      1. Detects PS 5.1 and PS7 (pwsh) availability + versions.
      2. Installs the SPO Management Shell + PnP.PowerShell if missing (CurrentUser).
      3. Attempts Import-Module of the SPO shell under BOTH PS7 and PS5.1, capturing the
         real success/failure + error so README can record what actually happened here.
    It performs NO tenant connections and NO mutations — import probing only.

    Run with: pwsh -File scripts/Test-SpoHosting.ps1   (or under powershell.exe; it adapts)
    Emits a JSON finding to stdout and to data/spo-hosting-finding.json.
.PARAMETER SkipInstall
    Probe only the currently-installed modules; do not install anything.
#>
[CmdletBinding()]
param(
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$spoModule = 'Microsoft.Online.SharePoint.PowerShell'
$pnpModule = 'PnP.PowerShell'

function Resolve-Pwsh {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Resolve-WinPowerShell {
    $p = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return (Test-Path $p) ? $p : $null
}

function Get-ModuleVersionInHost {
    param([string]$ExePath, [string]$ModuleName)
    if (-not $ExePath) { return $null }
    $script = "(Get-Module -ListAvailable -Name '$ModuleName' | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()"
    $out = & $ExePath -NoProfile -Command $script 2>$null
    return ($out | Select-Object -Last 1)
}

function Test-ModuleImportsInHost {
    param([string]$ExePath, [string]$ModuleName)
    if (-not $ExePath) { return [pscustomobject]@{ available = $false; imported = $false; error = 'host not present' } }
    $script = @"
try {
    Import-Module '$ModuleName' -ErrorAction Stop
    'IMPORT_OK'
} catch {
    'IMPORT_FAIL: ' + `$_.Exception.Message
}
"@
    $out = & $ExePath -NoProfile -Command $script 2>&1 | Out-String
    $ok = $out -match 'IMPORT_OK'
    return [pscustomobject]@{
        available = $true
        imported  = [bool]$ok
        error     = ($ok ? $null : ($out.Trim()))
    }
}

$pwshExe = Resolve-Pwsh
$winPs   = Resolve-WinPowerShell

Write-Host 'SPO hosting risk spike' -ForegroundColor Cyan
Write-Host ("  PS7 (pwsh):       {0}" -f ($pwshExe ?? 'NOT FOUND'))
Write-Host ("  Win PowerShell:   {0}" -f ($winPs ?? 'NOT FOUND'))

if (-not $SkipInstall) {
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
    foreach ($m in @($spoModule, $pnpModule)) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Host ("  installing {0} ..." -f $m) -ForegroundColor Yellow
            try { Install-Module $m -Scope CurrentUser -Force -Repository PSGallery }
            catch { Write-Warning ("install of {0} failed: {1}" -f $m, $_.Exception.Message) }
        }
    }
}

$spoVersion = Get-ModuleVersionInHost -ExePath ($pwshExe ?? $winPs) -ModuleName $spoModule
$pnpVersion = Get-ModuleVersionInHost -ExePath ($pwshExe ?? $winPs) -ModuleName $pnpModule

$spoInPwsh = Test-ModuleImportsInHost -ExePath $pwshExe -ModuleName $spoModule
$spoInWin  = Test-ModuleImportsInHost -ExePath $winPs   -ModuleName $spoModule
$pnpInPwsh = Test-ModuleImportsInHost -ExePath $pwshExe -ModuleName $pnpModule

# Decide the recommended approach from the evidence.
$recommendation =
    if ($spoInPwsh.imported) {
        'DIRECT_PS7 — SPO Management Shell imports under PS7; use it in-process.'
    }
    elseif ($spoInWin.imported) {
        'SIDECAR_51 — SPO Management Shell imports only under Windows PowerShell 5.1; invoke SPO cross-tenant cmdlets via a 5.1 sidecar process, return JSON to PS7.'
    }
    elseif ($pnpInPwsh.imported) {
        'PNP_PARTIAL — SPO Management Shell unavailable; PnP.PowerShell loads under PS7 but does NOT cover the cross-tenant relationship cmdlets. Still need a 5.1 sidecar for Set-SPOCrossTenantRelationship & content-move cmdlets.'
    }
    else {
        'UNRESOLVED — neither host imported the SPO shell; investigate module install before committing.'
    }

$finding = [ordered]@{
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    hosts = [ordered]@{
        ps7   = $pwshExe
        win51 = $winPs
    }
    spoManagementShell = [ordered]@{
        installedVersion = $spoVersion
        importsUnderPS7  = $spoInPwsh
        importsUnderWin51 = $spoInWin
    }
    pnpPowerShell = [ordered]@{
        installedVersion = $pnpVersion
        importsUnderPS7  = $pnpInPwsh
    }
    recommendation = $recommendation
}

$dataDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
$outPath = Join-Path $dataDir 'spo-hosting-finding.json'
($finding | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $outPath -Encoding utf8

Write-Host ''
Write-Host 'RECOMMENDATION:' -ForegroundColor Green
Write-Host "  $recommendation"
Write-Host ''
Write-Host "Full finding written to: $outPath" -ForegroundColor DarkGray
$finding | ConvertTo-Json -Depth 8

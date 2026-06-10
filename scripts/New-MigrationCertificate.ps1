#requires -Version 5.1
<#
.SYNOPSIS
    Creates a self-signed certificate for app-only authentication and exports the public
    key (.cer) for upload to an Entra app registration.
.DESCRIPTION
    The PRIVATE key stays in the Windows certificate store on this machine (CurrentUser\My)
    so the tool can authenticate; only the PUBLIC .cer is exported for upload. Run once per
    tenant (or reuse one cert across both tenants' app registrations). Record the printed
    thumbprint into config/config.json.

    Example:
      pwsh -File scripts/New-MigrationCertificate.ps1 -Name "M365Migration-Source" -OutDir .\certs
.PARAMETER Name
    Friendly subject/name, e.g. "M365Migration-Source".
.PARAMETER OutDir
    Folder to write the .cer into (gitignored; create under .\certs).
.PARAMETER Months
    Validity in months (default 24).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Name,
    [string]$OutDir = '.\certs',
    [int]$Months = 24
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$cert = New-SelfSignedCertificate `
    -Subject "CN=$Name" `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddMonths($Months)

$cerPath = Join-Path $OutDir "$Name.cer"
Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null

Write-Host ''
Write-Host "Certificate created in CurrentUser\My (private key stays here)." -ForegroundColor Green
Write-Host ("  Subject:    CN={0}" -f $Name)
Write-Host ("  Thumbprint: {0}" -f $cert.Thumbprint) -ForegroundColor Cyan
Write-Host ("  Expires:    {0:yyyy-MM-dd}" -f $cert.NotAfter)
Write-Host ("  Public .cer: {0}" -f (Resolve-Path $cerPath).Path)
Write-Host ''
Write-Host 'Next:' -ForegroundColor Yellow
Write-Host "  1. Upload the .cer to the Entra app registration (Certificates & secrets > Certificates)."
Write-Host "  2. Put the thumbprint above into config/config.json for the matching tenant/service."
Write-Host "  3. Keep the .cer out of source control (the /certs folder is gitignored)."

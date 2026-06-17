#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Pre-migration manifest / inventory (Phase 9). Read-only against the source tenant.
.DESCRIPTION
    Captures an inventory SNAPSHOT before any move: mailboxes (size + item count),
    OneDrive sites (URL + storage), and SharePoint sites (URL + template + storage). This is
    NOT a content backup — a tool like this cannot back up mailbox/OneDrive/SharePoint
    content. The realistic restore path is keeping the SOURCE tenant intact through a
    retention window; this manifest is the verifiable record of what existed (used to prove
    no data loss and to feed reconciliation).

    GUARDRAIL #4: EXO mailbox cmdlets are post-connect REST and guarded by Assert-CmdletReady;
    SPO cmdlets were verified offline.

    Depends on State.psm1 in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')

function Test-ExoConfigured { param($T) $e = $T.exchangeOnline; return (($script:Placeholders -notcontains $e.appId) -and ($script:Placeholders -notcontains $e.certThumbprint) -and ($script:Placeholders -notcontains $e.organization)) }
function Test-SpoConfigured { param($T) $s = $T.sharePoint; return (($script:Placeholders -notcontains $s.appId) -and ($script:Placeholders -notcontains $s.certThumbprint) -and ($script:Placeholders -notcontains $s.adminUrl)) }

function Assert-CmdletReady {
    param([string]$Name, [string[]]$RequiredParameters = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Cmdlet '$Name' not available (not connected?). Verify before use (guardrail #4)." }
    $missing = @($RequiredParameters | Where-Object { $_ -notin @($cmd.Parameters.Keys) })
    if ($missing.Count -gt 0) { throw "Cmdlet '$Name' missing parameter(s): $($missing -join ', ') (guardrail #4)." }
}

function ConvertTo-Bytes {
    # EXO TotalItemSize prints like '1.5 GB (1,610,612,736 bytes)'. Extract the byte count.
    param($Value)
    $s = [string]$Value
    if ($s -match '\(([\d,]+)\s*bytes\)') { return [int64]($Matches[1] -replace ',', '') }
    return $null
}

function New-Manifest {
    <#
    .SYNOPSIS
        Captures a source-tenant inventory snapshot into manifest_runs / manifest_items.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId,
        [ValidateSet('mailboxes', 'onedrive', 'sites')][string[]]$Scope = @('mailboxes', 'onedrive', 'sites'))

    $src = $Config.tenants.source
    $manifestId = 'mf-{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')), ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $now = [DateTime]::UtcNow.ToString('o')
    $items = [System.Collections.Generic.List[object]]::new()

    function Add-Item($kind, $identity, $name, $size, $count, $detail) {
        $items.Add(@{ kind = $kind; identity = $identity; name = $name; size = $size; count = $count; detail = $detail })
    }

    # Mailboxes (EXO).
    if ('mailboxes' -in $Scope -and (Test-ExoConfigured $src)) {
        try {
            Import-Module ExchangeOnlineManagement -ErrorAction Stop
            $e = $src.exchangeOnline
            Connect-ExchangeOnline -AppId $e.appId -Organization $e.organization -CertificateThumbprint $e.certThumbprint -ShowBanner:$false -ShowProgress:$false -ErrorAction Stop
            Assert-CmdletReady -Name 'Get-Mailbox'
            foreach ($mb in @(Get-Mailbox -ResultSize Unlimited -ErrorAction Stop)) {
                $size = $null; $cnt = $null
                try { $st = Get-MailboxStatistics -Identity $mb.PrimarySmtpAddress -ErrorAction Stop; $size = ConvertTo-Bytes $st.TotalItemSize; $cnt = [int]$st.ItemCount } catch { }
                Add-Item 'mailbox' ([string]$mb.PrimarySmtpAddress) ([string]$mb.DisplayName) $size $cnt ([ordered]@{ type = [string]$mb.RecipientTypeDetails })
            }
        }
        catch { Add-Item 'mailbox' '(error)' $_.Exception.Message $null $null $null }
        finally { try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { } }
    }

    # OneDrive + SharePoint sites (SPO).
    if (('onedrive' -in $Scope -or 'sites' -in $Scope) -and (Test-SpoConfigured $src)) {
        try {
            Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop
            $s = $src.sharePoint
            Connect-SPOService -Url $s.adminUrl -ClientId $s.appId -Certificate (Get-SpoCertificate $s.certThumbprint) -TenantId $src.tenantId -ErrorAction Stop
            if ('onedrive' -in $Scope) {
                foreach ($site in @(Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'" -ErrorAction Stop)) {
                    Add-Item 'onedrive' ([string]$site.Url) ([string]$site.Owner) ([int64]$site.StorageUsageCurrent * 1MB) $null ([ordered]@{ owner = [string]$site.Owner })
                }
            }
            if ('sites' -in $Scope) {
                foreach ($site in @(Get-SPOSite -Limit All -ErrorAction Stop)) {
                    Add-Item 'site' ([string]$site.Url) ([string]$site.Title) ([int64]$site.StorageUsageCurrent * 1MB) $null ([ordered]@{ template = [string]$site.Template; owner = [string]$site.Owner })
                }
            }
        }
        catch { Add-Item 'site' '(error)' $_.Exception.Message $null $null $null }
        finally { try { Disconnect-SPOService -ErrorAction SilentlyContinue | Out-Null } catch { } }
    }

    # Persist.
    $mbCount = @($items | Where-Object { $_.kind -eq 'mailbox' }).Count
    $odCount = @($items | Where-Object { $_.kind -eq 'onedrive' }).Count
    $stCount = @($items | Where-Object { $_.kind -eq 'site' }).Count
    Invoke-DbQuery -Query 'INSERT INTO manifest_runs (manifest_id, created_utc, mailbox_count, onedrive_count, site_count) VALUES (@id,@t,@m,@o,@s);' `
        -SqlParameters @{ id = $manifestId; t = $now; m = $mbCount; o = $odCount; s = $stCount } | Out-Null
    foreach ($it in $items) {
        Invoke-DbQuery -Query @'
INSERT INTO manifest_items (manifest_id, kind, identity, display_name, size_bytes, item_count, detail, created_utc)
VALUES (@mid,@k,@id,@dn,@sz,@ic,@d,@t);
'@ -SqlParameters @{ mid = $manifestId; k = $it.kind; id = $it.identity; dn = $it.name; sz = $it.size; ic = $it.count; d = ($it.detail | ConvertTo-Json -Compress -Depth 5); t = $now } | Out-Null
    }
    Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action 'manifest.capture' -Target $manifestId -Detail "mailboxes=$mbCount onedrive=$odCount sites=$stCount"
    return Get-Manifest -ManifestId $manifestId
}

function Get-Manifest {
    [CmdletBinding()] param([string]$ManifestId)
    if (-not $ManifestId) {
        $first = @(Invoke-DbQuery -Query 'SELECT manifest_id FROM manifest_runs ORDER BY created_utc DESC LIMIT 1;') | Select-Object -First 1
        if ($first) { $ManifestId = $first.manifest_id }
    }
    if (-not $ManifestId) { return $null }
    $run = @(Invoke-DbQuery -Query 'SELECT * FROM manifest_runs WHERE manifest_id=@id;' -SqlParameters @{ id = $ManifestId }) | Select-Object -First 1
    $rows = Invoke-DbQuery -Query 'SELECT kind, identity, display_name, size_bytes, item_count, detail FROM manifest_items WHERE manifest_id=@id ORDER BY kind, identity;' -SqlParameters @{ id = $ManifestId }
    return [ordered]@{
        manifestId = $ManifestId; createdUtc = $run.created_utc
        mailboxCount = $run.mailbox_count; oneDriveCount = $run.onedrive_count; siteCount = $run.site_count
        items = @($rows) | ForEach-Object { [ordered]@{ kind = $_.kind; identity = $_.identity; displayName = $_.display_name; sizeBytes = $_.size_bytes; itemCount = $_.item_count } }
    }
}

function Get-Manifests {
    [CmdletBinding()] param()
    $rows = Invoke-DbQuery -Query 'SELECT * FROM manifest_runs ORDER BY created_utc DESC;'
    return @($rows) | ForEach-Object { [ordered]@{ manifestId = $_.manifest_id; createdUtc = $_.created_utc; mailboxCount = $_.mailbox_count; oneDriveCount = $_.onedrive_count; siteCount = $_.site_count } }
}

Export-ModuleMember -Function New-Manifest, Get-Manifest, Get-Manifests

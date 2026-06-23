#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Copy-based OneDrive + SharePoint file migration via Microsoft Graph. Source intact.
.DESCRIPTION
    Copies files + folder structure from a source OneDrive or SharePoint document library to
    the target, via app-only Graph. No Azure, no native cross-tenant move feature. Files only
    (v1) — sharing/permissions are NOT copied (access resets to target defaults).

    Two phases: download the source drive tree to a temp dir (source context), then upload by
    path to the target drive (target context). Small files via direct PUT; large files via a
    chunked upload session. Throttling-aware.

    REQUIRED Graph APPLICATION permissions (admin-consented):
      Source app: Files.Read.All  (OneDrive) and/or Sites.Read.All  (SharePoint)
      Target app: Files.ReadWrite.All (OneDrive) and/or Sites.ReadWrite.All (SharePoint)
    OneDrive copy needs the TARGET user's OneDrive to be provisioned (licensed + initialised).

    Depends on State.psm1 and Connections.psm1 (Import-GraphModules) in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')
function Test-GraphConfigured { param($T) $g = $T.graph; return (($script:Placeholders -notcontains $g.appId) -and ($script:Placeholders -notcontains $g.certThumbprint) -and ($script:Placeholders -notcontains $T.tenantId)) }
function Connect-TenantGraph { param($Tenant) Import-GraphModules; Connect-MgGraph -ClientId $Tenant.graph.appId -TenantId $Tenant.tenantId -CertificateThumbprint $Tenant.graph.certThumbprint -NoWelcome -ErrorAction Stop }
function Disconnect-Graph { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }

function Invoke-Graph {
    param([string]$Method, [string]$Uri, $Body, [string]$ContentType, [string]$OutputFilePath, [string]$InputFilePath, [int]$MaxAttempts = 6)
    if ($Uri.StartsWith('/')) { $Uri = "https://graph.microsoft.com/v1.0$Uri" }
    for ($a = 1; ; $a++) {
        try {
            $p = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
            if ($null -ne $Body) { $p.Body = $Body }
            if ($ContentType) { $p.ContentType = $ContentType }
            if ($OutputFilePath) { $p.OutputFilePath = $OutputFilePath }
            if ($InputFilePath) { $p.InputFilePath = $InputFilePath }
            return Invoke-MgGraphRequest @p
        }
        catch {
            $msg = $_.Exception.Message
            if (($msg -match '429|TooManyRequests|throttl|ServiceUnavailable|\b50[234]\b') -and $a -lt $MaxAttempts) { Start-Sleep -Seconds ([Math]::Min(10 * $a, 90)); continue }
            throw
        }
    }
}

function Resolve-DriveId {
    param([string]$Type, [string]$Identity)
    if ($Type -eq 'onedrive') {
        return (Invoke-Graph -Method GET -Uri "/users/$Identity/drive?`$select=id").id
    }
    $u = [uri]$Identity
    $site = Invoke-Graph -Method GET -Uri "/sites/$($u.Host):$($u.AbsolutePath)"
    return (Invoke-Graph -Method GET -Uri "/sites/$($site.id)/drive?`$select=id").id
}

function Invoke-DriveDownload {
    param([string]$DriveId, [string]$ItemId, [string]$RelPath, [string]$TempRoot, [string]$JobId)
    $uri = "/drives/$DriveId/items/$ItemId/children?`$top=200&`$select=id,name,folder,file,size"
    while ($uri) {
        $r = Invoke-Graph -Method GET -Uri $uri
        foreach ($it in $r.value) {
            $child = if ($RelPath) { "$RelPath/$($it.name)" } else { [string]$it.name }
            if ($it.ContainsKey('folder')) {
                Invoke-DriveDownload -DriveId $DriveId -ItemId $it.id -RelPath $child -TempRoot $TempRoot -JobId $JobId
            }
            elseif ($it.ContainsKey('file')) {
                $dest = Join-Path $TempRoot $child
                New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
                try {
                    Invoke-Graph -Method GET -Uri "/drives/$DriveId/items/$($it.id)/content" -OutputFilePath $dest
                    Invoke-DbQuery -Query 'UPDATE file_copy_jobs SET files_total=files_total+1, bytes_total=bytes_total+@b, updated_utc=@t WHERE job_id=@id;' -SqlParameters @{ b = [int64]$it.size; t = [DateTime]::UtcNow.ToString('o'); id = $JobId } | Out-Null
                }
                catch { }
            }
        }
        $uri = if ($r.ContainsKey('@odata.nextLink')) { $r.'@odata.nextLink' } else { $null }
    }
}

function Send-LargeFile {
    param([string]$DriveId, [string]$EncPath, [string]$File, [int64]$Size)
    $session = Invoke-Graph -Method POST -Uri "/drives/$DriveId/root:/$EncPath`:/createUploadSession" `
        -Body (@{ item = @{ '@microsoft.graph.conflictBehavior' = 'replace' } } | ConvertTo-Json) -ContentType 'application/json'
    $url = $session.uploadUrl
    $chunk = 5242880  # 5 MB (multiple of 320 KiB, as Graph requires)
    $fs = [IO.File]::OpenRead($File)
    try {
        $buf = [byte[]]::new($chunk); $pos = [int64]0
        while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $end = $pos + $read - 1
            $data = if ($read -eq $buf.Length) { $buf } else { $buf[0..($read - 1)] }
            Invoke-WebRequest -Method Put -Uri $url -Body $data -Headers @{ 'Content-Range' = "bytes $pos-$end/$Size" } -ContentType 'application/octet-stream' -UseBasicParsing | Out-Null
            $pos += $read
        }
    }
    finally { $fs.Close() }
}

function Invoke-DriveUpload {
    param([string]$DriveId, [string]$TempRoot, [string]$JobId)
    foreach ($f in (Get-ChildItem -LiteralPath $TempRoot -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($TempRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $encPath = (($rel -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        try {
            if ($f.Length -lt 4194304) {
                Invoke-Graph -Method PUT -Uri "/drives/$DriveId/root:/$encPath`:/content" -InputFilePath $f.FullName -ContentType 'application/octet-stream' | Out-Null
            }
            else { Send-LargeFile -DriveId $DriveId -EncPath $encPath -File $f.FullName -Size $f.Length }
            Invoke-DbQuery -Query 'UPDATE file_copy_jobs SET files_done=files_done+1, updated_utc=@t WHERE job_id=@id;' -SqlParameters @{ t = [DateTime]::UtcNow.ToString('o'); id = $JobId } | Out-Null
        }
        catch { }
    }
}

function Invoke-FileCopy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][ValidateSet('onedrive', 'site')][string]$Type,
        [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)

    $src = $Config.tenants.source; $tgt = $Config.tenants.target
    if (-not (Test-GraphConfigured $src) -or -not (Test-GraphConfigured $tgt)) { throw 'Graph is not configured for both tenants.' }
    $temp = Join-Path (Split-Path $env:MIG_DB_PATH -Parent) "filecopy\$JobId"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Update-FileCopyJob -JobId $JobId -Set @{ status = 'running'; phase = 'download' }

    try {
        Connect-TenantGraph -Tenant $src
        $srcDrive = Resolve-DriveId -Type $Type -Identity $Source
        Invoke-DriveDownload -DriveId $srcDrive -ItemId 'root' -RelPath '' -TempRoot $temp -JobId $JobId
    }
    finally { Disconnect-Graph }

    Update-FileCopyJob -JobId $JobId -Set @{ phase = 'upload' }
    try {
        Connect-TenantGraph -Tenant $tgt
        $tgtDrive = Resolve-DriveId -Type $Type -Identity $Target
        Invoke-DriveUpload -DriveId $tgtDrive -TempRoot $temp -JobId $JobId
    }
    finally { Disconnect-Graph }

    Update-FileCopyJob -JobId $JobId -Set @{ status = 'completed'; phase = 'done' }
    Add-AuditEntry -RunId $JobId -CorrelationId (New-CorrelationId) -Action "filecopy.$Type" -Target $Source -Detail "-> $Target (files only, source untouched)"
    return Get-FileCopyJob -JobId $JobId
}

function Update-FileCopyJob {
    param([string]$JobId, [hashtable]$Set)
    $cols = @(); $params = @{ id = $JobId; t = [DateTime]::UtcNow.ToString('o') }
    foreach ($k in $Set.Keys) { $cols += "$k = @$k"; $params[$k] = $Set[$k] }
    $cols += 'updated_utc = @t'
    Invoke-DbQuery -Query "UPDATE file_copy_jobs SET $($cols -join ', ') WHERE job_id = @id;" -SqlParameters $params | Out-Null
}

function New-FileCopyJob {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)
    $jobId = 'fc-{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')), ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $now = [DateTime]::UtcNow.ToString('o')
    Invoke-DbQuery -Query 'INSERT INTO file_copy_jobs (job_id, type, source, target, status, created_utc, updated_utc) VALUES (@id,@ty,@s,@t,''created'',@n,@n);' `
        -SqlParameters @{ id = $jobId; ty = $Type; s = $Source; t = $Target; n = $now } | Out-Null
    return $jobId
}
function ConvertFrom-FileCopyRow { param($r) [ordered]@{ jobId = $r.job_id; type = $r.type; source = $r.source; target = $r.target; status = $r.status; phase = $r.phase; error = $r.error; filesTotal = $r.files_total; filesDone = $r.files_done; bytesTotal = $r.bytes_total; createdUtc = $r.created_utc; updatedUtc = $r.updated_utc } }
function Get-FileCopyJob { [CmdletBinding()] param([Parameter(Mandatory)][string]$JobId) $r = @(Invoke-DbQuery -Query 'SELECT * FROM file_copy_jobs WHERE job_id=@id;' -SqlParameters @{ id = $JobId }) | Select-Object -First 1; if (-not $r) { return $null }; ConvertFrom-FileCopyRow $r }
function Get-FileCopyJobs { [CmdletBinding()] param() @(Invoke-DbQuery -Query 'SELECT * FROM file_copy_jobs ORDER BY created_utc DESC;') | ForEach-Object { ConvertFrom-FileCopyRow $_ } }

Export-ModuleMember -Function Invoke-FileCopy, New-FileCopyJob, Get-FileCopyJob, Get-FileCopyJobs, Update-FileCopyJob

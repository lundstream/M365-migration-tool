#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Copy-based cross-tenant mailbox migration via Microsoft Graph (Phase: copy engine).
.DESCRIPTION
    Copies mail (as MIME for fidelity), calendar events, and contacts from a SOURCE mailbox
    to a TARGET mailbox using app-only Graph. The source is read-only and never deleted — no
    Azure Key Vault, no add-on licence, no "delete on complete". Target must be a licensed
    mailbox.

    Two phases (avoids holding two tenant contexts at once):
      1. download — connect source Graph, pull folders + MIME messages to a temp dir, plus
         events/contacts to JSON.
      2. upload — connect target Graph, recreate folders, import MIME, create events/contacts.

    Throttling-aware (honors Graph 429/5xx with backoff). MVP runs synchronously; for large
    mailboxes this should move to a background task.

    REQUIRED Graph APPLICATION permissions (admin-consented):
      Source app: Mail.Read, Calendars.Read, Contacts.Read
      Target app: Mail.ReadWrite, Calendars.ReadWrite, Contacts.ReadWrite

    Depends on State.psm1 and Connections.psm1 (Import-GraphModules) in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')
function Test-GraphConfigured { param($T) $g = $T.graph; return (($script:Placeholders -notcontains $g.appId) -and ($script:Placeholders -notcontains $g.certThumbprint) -and ($script:Placeholders -notcontains $T.tenantId)) }

function Connect-TenantGraph {
    param($Tenant)
    Import-GraphModules
    Connect-MgGraph -ClientId $Tenant.graph.appId -TenantId $Tenant.tenantId -CertificateThumbprint $Tenant.graph.certThumbprint -NoWelcome -ErrorAction Stop
}
function Disconnect-Graph { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }

function Invoke-Graph {
    <#
    .SYNOPSIS
        Graph REST call with throttling-aware retry (honors 429 / 5xx).
    #>
    param([string]$Method, [string]$Uri, $Body, [string]$ContentType, [string]$OutputFilePath, [int]$MaxAttempts = 6)
    # Invoke-MgGraphRequest mishandles RELATIVE URIs that carry a query string (returns 404);
    # always use the full v1.0 base. Absolute @odata.nextLink URLs pass through unchanged.
    if ($Uri.StartsWith('/')) { $Uri = "https://graph.microsoft.com/v1.0$Uri" }
    for ($a = 1; ; $a++) {
        try {
            $p = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
            if ($null -ne $Body) { $p.Body = $Body }
            if ($ContentType) { $p.ContentType = $ContentType }
            if ($OutputFilePath) { $p.OutputFilePath = $OutputFilePath }
            return Invoke-MgGraphRequest @p
        }
        catch {
            $msg = $_.Exception.Message
            if (($msg -match '429|TooManyRequests|throttl|ServiceUnavailable|\b50[234]\b') -and $a -lt $MaxAttempts) {
                Start-Sleep -Seconds ([Math]::Min(10 * $a, 90)); continue
            }
            throw
        }
    }
}

function Update-CopyJob {
    param([string]$JobId, [hashtable]$Set)
    $cols = @(); $params = @{ id = $JobId; t = [DateTime]::UtcNow.ToString('o') }
    foreach ($k in $Set.Keys) { $cols += "$k = @$k"; $params[$k] = $Set[$k] }
    $cols += 'updated_utc = @t'
    Invoke-DbQuery -Query "UPDATE mailbox_copy_jobs SET $($cols -join ', ') WHERE job_id = @id;" -SqlParameters $params | Out-Null
}

function Get-MailFolderTree {
    param([string]$User)
    $list = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $seed = "/users/$User/mailFolders?`$top=100&`$select=id,displayName,parentFolderId,childFolderCount,totalItemCount"
    $uri = $seed
    while ($uri) {
        $r = Invoke-Graph -Method GET -Uri $uri
        foreach ($f in $r.value) { $list.Add($f); if ([int]$f.childFolderCount -gt 0) { $stack.Push([string]$f.id) } }
        $uri = if ($r.ContainsKey('@odata.nextLink')) { $r.'@odata.nextLink' } else { $null }
    }
    while ($stack.Count -gt 0) {
        $parentId = $stack.Pop()
        $uri = "/users/$User/mailFolders/$parentId/childFolders?`$top=100&`$select=id,displayName,parentFolderId,childFolderCount,totalItemCount"
        while ($uri) {
            $r = Invoke-Graph -Method GET -Uri $uri
            foreach ($f in $r.value) { $list.Add($f); if ([int]$f.childFolderCount -gt 0) { $stack.Push([string]$f.id) } }
            $uri = if ($r.ContainsKey('@odata.nextLink')) { $r.'@odata.nextLink' } else { $null }
        }
    }
    return $list
}

function Get-WellKnownFolderMap {
    param([string]$User)
    $names = @('inbox', 'archive', 'sentitems', 'drafts', 'deleteditems', 'junkemail', 'outbox', 'clutter', 'conflicts', 'syncissues', 'scheduled')
    $map = @{}
    foreach ($n in $names) {
        try { $f = Invoke-Graph -Method GET -Uri "/users/$User/mailFolders/$n`?`$select=id"; if ($f.id) { $map[[string]$f.id] = $n } } catch { }
    }
    return $map
}

$script:EventSelect = 'subject,body,start,end,location,isAllDay,attendees,categories,recurrence,importance,sensitivity,showAs,reminderMinutesBeforeStart,responseRequested'
$script:ContactSelect = 'givenName,surname,displayName,middleName,nickName,emailAddresses,businessPhones,homePhones,mobilePhone,companyName,jobTitle,department,officeLocation,businessAddress,homeAddress,personalNotes,birthday'

function Invoke-MailboxCopy {
    <#
    .SYNOPSIS
        Copies mail + calendar + contacts from source to target (synchronous MVP).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$SourceUpn, [Parameter(Mandatory)][string]$TargetUpn,
        [string]$Scope = 'mail,calendar,contacts')

    $src = $Config.tenants.source; $tgt = $Config.tenants.target
    if (-not (Test-GraphConfigured $src) -or -not (Test-GraphConfigured $tgt)) { throw 'Graph is not configured for both tenants.' }
    $do = @($Scope -split ',' | ForEach-Object { $_.Trim() })

    $root = Join-Path (Split-Path $env:MIG_DB_PATH -Parent) "copy\$JobId"
    $mailDir = Join-Path $root 'mail'
    New-Item -ItemType Directory -Path $mailDir -Force | Out-Null
    Update-CopyJob -JobId $JobId -Set @{ status = 'running'; phase = 'download' }

    # ---------------- DOWNLOAD (source) ----------------
    $folders = @()
    try {
        Connect-TenantGraph -Tenant $src
        if ('mail' -in $do) {
            $tree = Get-MailFolderTree -User $SourceUpn
            $wk = Get-WellKnownFolderMap -User $SourceUpn
            $idx = 0; $mailTotal = 0
            foreach ($f in $tree) {
                $fKey = "f{0:000}" -f $idx; $idx++
                $fDir = Join-Path $mailDir $fKey; New-Item -ItemType Directory -Path $fDir -Force | Out-Null
                $folders += [ordered]@{ key = $fKey; id = [string]$f.id; displayName = [string]$f.displayName; parentFolderId = [string]$f.parentFolderId; wellKnown = ($wk[[string]$f.id]); count = 0 }
                $mi = 0
                $uri = "/users/$SourceUpn/mailFolders/$($f.id)/messages?`$top=50&`$select=id"
                while ($uri) {
                    $r = Invoke-Graph -Method GET -Uri $uri
                    foreach ($m in $r.value) {
                        $file = Join-Path $fDir ("m{0:00000}.eml" -f $mi); $mi++
                        try { Invoke-Graph -Method GET -Uri "/users/$SourceUpn/messages/$($m.id)/`$value" -OutputFilePath $file; $mailTotal++ } catch { }
                    }
                    $uri = if ($r.ContainsKey('@odata.nextLink')) { $r.'@odata.nextLink' } else { $null }
                }
                ($folders[-1]).count = $mi
            }
            ($folders | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $root 'folders.json') -Encoding utf8
            Update-CopyJob -JobId $JobId -Set @{ mail_total = $mailTotal }
        }
        if ('calendar' -in $do) {
            $events = @(); $uri = "/users/$SourceUpn/events?`$top=50&`$select=$script:EventSelect"
            while ($uri) { $r = Invoke-Graph -Method GET -Uri $uri; $events += $r.value; $uri = if ($r.ContainsKey('@odata.nextLink')) { $r.'@odata.nextLink' } else { $null } }
            ($events | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath (Join-Path $root 'events.json') -Encoding utf8
            Update-CopyJob -JobId $JobId -Set @{ events_total = @($events).Count }
        }
        if ('contacts' -in $do) {
            $contacts = @(); $uri = "/users/$SourceUpn/contacts?`$top=50&`$select=$script:ContactSelect"
            while ($uri) { $r = Invoke-Graph -Method GET -Uri $uri; $contacts += $r.value; $uri = if ($r.ContainsKey('@odata.nextLink')) { $r.'@odata.nextLink' } else { $null } }
            ($contacts | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $root 'contacts.json') -Encoding utf8
            Update-CopyJob -JobId $JobId -Set @{ contacts_total = @($contacts).Count }
        }
    }
    finally { Disconnect-Graph }

    # ---------------- UPLOAD (target) ----------------
    Update-CopyJob -JobId $JobId -Set @{ phase = 'upload' }
    try {
        Connect-TenantGraph -Tenant $tgt
        if ('mail' -in $do -and (Test-Path (Join-Path $root 'folders.json'))) {
            $folders = @(Get-Content (Join-Path $root 'folders.json') -Raw | ConvertFrom-Json)
            $tgtFolderId = @{}   # source folder id -> target folder id
            foreach ($f in $folders) {
                $targetId = $null
                if ($f.wellKnown) {
                    try { $targetId = (Invoke-Graph -Method GET -Uri "/users/$TargetUpn/mailFolders/$($f.wellKnown)`?`$select=id").id } catch { }
                }
                if (-not $targetId) {
                    $parentTid = if ($f.parentFolderId -and $tgtFolderId.ContainsKey($f.parentFolderId)) { $tgtFolderId[$f.parentFolderId] } else { $null }
                    $createUri = if ($parentTid) { "/users/$TargetUpn/mailFolders/$parentTid/childFolders" } else { "/users/$TargetUpn/mailFolders" }
                    try { $targetId = (Invoke-Graph -Method POST -Uri $createUri -Body (@{ displayName = $f.displayName } | ConvertTo-Json) -ContentType 'application/json').id } catch { }
                }
                if ($targetId) { $tgtFolderId[[string]$f.id] = $targetId }

                $fDir = Join-Path $mailDir $f.key
                if ($targetId -and (Test-Path $fDir)) {
                    foreach ($eml in (Get-ChildItem -LiteralPath $fDir -Filter '*.eml' -ErrorAction SilentlyContinue)) {
                        try {
                            # MIME import is only accepted at the root /messages endpoint; create
                            # there, then move the message into the matching target folder.
                            $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($eml.FullName))
                            $created = Invoke-Graph -Method POST -Uri "/users/$TargetUpn/messages" -Body $b64 -ContentType 'text/plain'
                            if ($targetId -and $created.id) {
                                try { Invoke-Graph -Method POST -Uri "/users/$TargetUpn/messages/$($created.id)/move" -Body (@{ destinationId = $targetId } | ConvertTo-Json) -ContentType 'application/json' | Out-Null } catch { }
                            }
                            Invoke-DbQuery -Query 'UPDATE mailbox_copy_jobs SET mail_done = mail_done + 1, updated_utc=@t WHERE job_id=@id;' -SqlParameters @{ t = [DateTime]::UtcNow.ToString('o'); id = $JobId } | Out-Null
                        }
                        catch { }
                    }
                }
            }
        }
        if ('calendar' -in $do -and (Test-Path (Join-Path $root 'events.json'))) {
            foreach ($e in @(Get-Content (Join-Path $root 'events.json') -Raw | ConvertFrom-Json)) {
                try { Invoke-Graph -Method POST -Uri "/users/$TargetUpn/events" -Body ($e | ConvertTo-Json -Depth 12) -ContentType 'application/json' | Out-Null
                    Invoke-DbQuery -Query 'UPDATE mailbox_copy_jobs SET events_done = events_done + 1, updated_utc=@t WHERE job_id=@id;' -SqlParameters @{ t = [DateTime]::UtcNow.ToString('o'); id = $JobId } | Out-Null } catch { }
            }
        }
        if ('contacts' -in $do -and (Test-Path (Join-Path $root 'contacts.json'))) {
            foreach ($c in @(Get-Content (Join-Path $root 'contacts.json') -Raw | ConvertFrom-Json)) {
                try { Invoke-Graph -Method POST -Uri "/users/$TargetUpn/contacts" -Body ($c | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
                    Invoke-DbQuery -Query 'UPDATE mailbox_copy_jobs SET contacts_done = contacts_done + 1, updated_utc=@t WHERE job_id=@id;' -SqlParameters @{ t = [DateTime]::UtcNow.ToString('o'); id = $JobId } | Out-Null } catch { }
            }
        }
    }
    finally { Disconnect-Graph }

    Update-CopyJob -JobId $JobId -Set @{ status = 'completed'; phase = 'done' }
    Add-AuditEntry -RunId $JobId -CorrelationId (New-CorrelationId) -Action 'mailbox.copy' -Target $SourceUpn -Detail "-> $TargetUpn ($Scope), source untouched"
    return Get-MailboxCopyJob -JobId $JobId
}

function New-MailboxCopyJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceUpn, [Parameter(Mandatory)][string]$TargetUpn, [string]$Scope = 'mail,calendar,contacts')
    $jobId = 'cp-{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')), ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $now = [DateTime]::UtcNow.ToString('o')
    Invoke-DbQuery -Query @'
INSERT INTO mailbox_copy_jobs (job_id, source_upn, target_upn, scope, status, created_utc, updated_utc)
VALUES (@id, @s, @t, @sc, 'created', @n, @n);
'@ -SqlParameters @{ id = $jobId; s = $SourceUpn; t = $TargetUpn; sc = $Scope; n = $now } | Out-Null
    return $jobId
}

function Get-MailboxCopyJob {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$JobId)
    $r = @(Invoke-DbQuery -Query 'SELECT * FROM mailbox_copy_jobs WHERE job_id=@id;' -SqlParameters @{ id = $JobId }) | Select-Object -First 1
    if (-not $r) { return $null }
    return ConvertFrom-CopyRow $r
}
function Get-MailboxCopyJobs {
    [CmdletBinding()] param()
    return @(Invoke-DbQuery -Query 'SELECT * FROM mailbox_copy_jobs ORDER BY created_utc DESC;') | ForEach-Object { ConvertFrom-CopyRow $_ }
}
function ConvertFrom-CopyRow {
    param($r)
    [ordered]@{
        jobId = $r.job_id; sourceUpn = $r.source_upn; targetUpn = $r.target_upn; scope = $r.scope
        status = $r.status; phase = $r.phase; error = $r.error
        mail = @{ total = $r.mail_total; done = $r.mail_done }
        events = @{ total = $r.events_total; done = $r.events_done }
        contacts = @{ total = $r.contacts_total; done = $r.contacts_done }
        createdUtc = $r.created_utc; updatedUtc = $r.updated_utc
    }
}

Export-ModuleMember -Function Invoke-MailboxCopy, New-MailboxCopyJob, Get-MailboxCopyJob, Get-MailboxCopyJobs, Update-CopyJob

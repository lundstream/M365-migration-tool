#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Identity mapping for the M365 migration tool (Phase 2). Read-only against tenants.
.DESCRIPTION
    Pulls users from source + target via Microsoft Graph (app-only cert), caches them in
    SQLite, auto-matches on UPN then proxyAddresses, flags matched / unmatched / conflict,
    supports CSV import/export, and validates that mapped target users actually exist
    (they are needed later as MailUsers). No mutations to either tenant.

    Depends on State.psm1 (Invoke-DbQuery) being loaded in the same runspace.
    Cmdlet: Get-MgUser -All -Property ... (verified: Microsoft.Graph.Users 2.36.1).
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')

function Test-GraphConfigured {
    param($Tenant)
    $g = $Tenant.graph
    return (($script:Placeholders -notcontains $g.appId) -and
            ($script:Placeholders -notcontains $g.certThumbprint) -and
            ($script:Placeholders -notcontains $Tenant.tenantId))
}

function ConvertTo-JsonArrayString {
    param([string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return '[]' }
    $escaped = $Items | ForEach-Object { '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"' }
    return '[' + ($escaped -join ',') + ']'
}

function Get-SmtpProxies {
    param($ProxyAddresses)
    $out = @()
    foreach ($p in @($ProxyAddresses)) {
        if ($p -and $p -match '^smtp:(.+)$') { $out += $Matches[1].ToLowerInvariant() }
    }
    return ($out | Select-Object -Unique)
}

function Get-DirectoryUsers {
    <#
    .SYNOPSIS
        Pulls users for one tenant from Graph (app-only cert). Returns normalized objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('source', 'target')][string]$Tenant,
        [Parameter(Mandatory)] $Config
    )
    $t = $Config.tenants.$Tenant
    if (-not (Test-GraphConfigured $t)) {
        throw "Graph is not configured for the $Tenant tenant. Set tenantId, graph.appId, and graph.certThumbprint in config.json."
    }

    try {
        Import-GraphModules
        Connect-MgGraph -ClientId $t.graph.appId -TenantId $t.tenantId -CertificateThumbprint $t.graph.certThumbprint -NoWelcome -ErrorAction Stop

        $users = Get-MgUser -All -Property 'id,userPrincipalName,displayName,mail,proxyAddresses,accountEnabled' -ErrorAction Stop
        return $users | ForEach-Object {
            [pscustomobject]@{
                user_id         = $_.Id
                upn             = $_.UserPrincipalName
                display_name    = $_.DisplayName
                mail            = $_.Mail
                proxy_addresses = (Get-SmtpProxies $_.ProxyAddresses)
                account_enabled = [int][bool]$_.AccountEnabled
            }
        }
    }
    finally {
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
}

function Sync-DirectoryUsers {
    <#
    .SYNOPSIS
        Pulls a tenant's users and refreshes the local directory_users cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('source', 'target')][string]$Tenant,
        [Parameter(Mandatory)] $Config
    )
    $users = Get-DirectoryUsers -Tenant $Tenant -Config $Config
    $now = [DateTime]::UtcNow.ToString('o')

    Invoke-DbQuery -Query 'DELETE FROM directory_users WHERE tenant = @t;' -SqlParameters @{ t = $Tenant } | Out-Null
    foreach ($u in $users) {
        Invoke-DbQuery -Query @'
INSERT INTO directory_users (tenant, user_id, upn, display_name, mail, proxy_addresses, account_enabled, fetched_utc)
VALUES (@tenant, @id, @upn, @dn, @mail, @proxies, @enabled, @fetched);
'@ -SqlParameters @{
            tenant  = $Tenant
            id      = $u.user_id
            upn     = $u.upn
            dn      = $u.display_name
            mail    = $u.mail
            proxies = (ConvertTo-JsonArrayString $u.proxy_addresses)
            enabled = $u.account_enabled
            fetched = $now
        } | Out-Null
    }
    return @{ tenant = $Tenant; count = @($users).Count; fetchedUtc = $now }
}

function Get-CachedUsers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('source', 'target')][string]$Tenant)
    $rows = Invoke-DbQuery -Query 'SELECT * FROM directory_users WHERE tenant = @t ORDER BY upn;' -SqlParameters @{ t = $Tenant }
    return @($rows) | ForEach-Object {
        [pscustomobject]@{
            user_id         = $_.user_id
            upn             = $_.upn
            display_name    = $_.display_name
            mail            = $_.mail
            proxy_addresses = @(($_.proxy_addresses | ConvertFrom-Json -ErrorAction SilentlyContinue))
            account_enabled = $_.account_enabled
        }
    }
}

function Save-Mapping {
    # Internal upsert helper for one mapping row.
    param(
        [string]$SourceUpn, [string]$SourceId, [string]$SourceDisplay,
        [string]$TargetUpn, [string]$TargetId, [string]$TargetDisplay,
        [int]$TargetExists, [string]$State, [string]$Method, [string]$Notes
    )
    Invoke-DbQuery -Query @'
INSERT INTO mappings (source_upn, source_id, source_display_name, target_upn, target_id,
                      target_display_name, target_exists, match_state, match_method, notes, updated_utc)
VALUES (@supn, @sid, @sdn, @tupn, @tid, @tdn, @texists, @state, @method, @notes, @updated)
ON CONFLICT(source_upn) DO UPDATE SET
    source_id = excluded.source_id,
    source_display_name = excluded.source_display_name,
    target_upn = excluded.target_upn,
    target_id = excluded.target_id,
    target_display_name = excluded.target_display_name,
    target_exists = excluded.target_exists,
    match_state = excluded.match_state,
    match_method = excluded.match_method,
    notes = excluded.notes,
    updated_utc = excluded.updated_utc;
'@ -SqlParameters @{
        supn = $SourceUpn; sid = $SourceId; sdn = $SourceDisplay
        tupn = $TargetUpn; tid = $TargetId; tdn = $TargetDisplay
        texists = $TargetExists; state = $State; method = $Method; notes = $Notes
        updated = [DateTime]::UtcNow.ToString('o')
    } | Out-Null
}

function Invoke-AutoMatch {
    <#
    .SYNOPSIS
        Auto-matches cached source users to target users on UPN then proxyAddresses,
        flags conflicts (ambiguous or many-to-one), and persists to the mappings table.
    #>
    [CmdletBinding()]
    param()

    $source = Get-CachedUsers -Tenant 'source'
    $target = Get-CachedUsers -Tenant 'target'
    if (@($source).Count -eq 0) { throw 'No cached source users. Sync the source tenant first.' }

    # Indexes over the target directory.
    $byUpn = @{}
    $byProxy = @{}
    foreach ($u in $target) {
        if ($u.upn) { $byUpn[$u.upn.ToLowerInvariant()] = $u }
        foreach ($p in $u.proxy_addresses) { if ($p) { ($byProxy[$p] ??= [System.Collections.Generic.List[object]]::new()).Add($u) } }
    }

    $decisions = @()
    foreach ($s in $source) {
        $candidates = [System.Collections.Generic.Dictionary[string, object]]::new()
        $method = $null

        if ($s.upn -and $byUpn.ContainsKey($s.upn.ToLowerInvariant())) {
            $hit = $byUpn[$s.upn.ToLowerInvariant()]
            $candidates[$hit.user_id] = $hit
            $method = 'upn'
        }
        foreach ($p in $s.proxy_addresses) {
            if ($byProxy.ContainsKey($p)) {
                foreach ($hit in $byProxy[$p]) {
                    if (-not $candidates.ContainsKey($hit.user_id)) { $candidates[$hit.user_id] = $hit }
                    if (-not $method) { $method = 'proxy' }
                }
            }
        }

        $count = $candidates.Count
        $state = if ($count -eq 0) { 'unmatched' } elseif ($count -eq 1) { 'matched' } else { 'conflict' }
        $tgt = if ($count -eq 1) { $candidates.Values | Select-Object -First 1 } else { $null }

        $decisions += [pscustomobject]@{
            source = $s; target = $tgt; state = $state
            method = if ($state -eq 'matched') { $method } elseif ($state -eq 'conflict') { 'conflict' } else { $null }
            candidateCount = $count
        }
    }

    # Many-to-one: a target claimed by >1 source becomes a conflict for all of them.
    $targetUse = @{}
    foreach ($d in $decisions | Where-Object { $_.target }) {
        ($targetUse[$d.target.user_id] ??= [System.Collections.Generic.List[object]]::new()).Add($d)
    }
    foreach ($entry in $targetUse.GetEnumerator()) {
        if ($entry.Value.Count -gt 1) {
            foreach ($d in $entry.Value) { $d.state = 'conflict'; $d.method = 'conflict'; $d.target = $null }
        }
    }

    foreach ($d in $decisions) {
        # $d.target is $null for unmatched/conflict rows; read its fields safely (StrictMode).
        $tUpn = if ($d.target) { $d.target.upn } else { $null }
        $tId = if ($d.target) { $d.target.user_id } else { $null }
        $tDn = if ($d.target) { $d.target.display_name } else { $null }
        Save-Mapping -SourceUpn $d.source.upn -SourceId $d.source.user_id -SourceDisplay $d.source.display_name `
            -TargetUpn $tUpn -TargetId $tId -TargetDisplay $tDn `
            -TargetExists ([int][bool]$d.target) -State $d.state -Method $d.method -Notes $null
    }

    return (Get-MappingSummary)
}

function Get-Mappings {
    [CmdletBinding()]
    param()
    $rows = Invoke-DbQuery -Query 'SELECT * FROM mappings ORDER BY match_state, source_upn;'
    return @($rows) | ForEach-Object {
        [pscustomobject]@{
            sourceUpn         = $_.source_upn
            sourceDisplayName = $_.source_display_name
            targetUpn         = $_.target_upn
            targetDisplayName = $_.target_display_name
            targetExists      = [bool]$_.target_exists
            matchState        = $_.match_state
            matchMethod       = $_.match_method
            notes             = $_.notes
            updatedUtc        = $_.updated_utc
        }
    }
}

function Get-MappingSummary {
    [CmdletBinding()]
    param()
    $rows = Get-Mappings
    return [ordered]@{
        total            = @($rows).Count
        matched          = @($rows | Where-Object { $_.matchState -eq 'matched' }).Count
        unmatched        = @($rows | Where-Object { $_.matchState -eq 'unmatched' }).Count
        conflict         = @($rows | Where-Object { $_.matchState -eq 'conflict' }).Count
        missingTarget    = @($rows | Where-Object { $_.targetUpn -and -not $_.targetExists }).Count
        rows             = $rows
    }
}

function Resolve-TargetByUpn {
    param([string]$Upn)
    if (-not $Upn) { return $null }
    $row = Invoke-DbQuery -Query 'SELECT * FROM directory_users WHERE tenant = ''target'' AND lower(upn) = lower(@u) LIMIT 1;' -SqlParameters @{ u = $Upn }
    return (@($row) | Select-Object -First 1)
}

function Save-Mappings {
    <#
    .SYNOPSIS
        Persists operator edits to mappings (manual target assignment), recomputing
        target existence against the cached target directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Rows)

    foreach ($r in @($Rows)) {
        $targetUpn = $r.targetUpn
        $tgt = Resolve-TargetByUpn -Upn $targetUpn
        $state = if (-not $targetUpn) { 'unmatched' } else { 'matched' }
        Save-Mapping -SourceUpn $r.sourceUpn -SourceId $r.sourceId -SourceDisplay $r.sourceDisplayName `
            -TargetUpn $targetUpn -TargetId ($tgt.user_id) -TargetDisplay ($tgt.display_name) `
            -TargetExists ([int][bool]$tgt) -State $state -Method 'manual' -Notes $r.notes
    }
    return (Get-MappingSummary)
}

function Import-MappingCsv {
    <#
    .SYNOPSIS
        Imports an explicit mapping from CSV text. Recognized columns (case-insensitive):
        SourceUpn, TargetUpn, Notes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Csv)

    $records = $Csv | ConvertFrom-Csv
    $imported = 0
    foreach ($rec in @($records)) {
        $props = $rec.PSObject.Properties.Name
        $srcCol = $props | Where-Object { $_ -match '^(source[_ ]?upn|source)$' } | Select-Object -First 1
        $tgtCol = $props | Where-Object { $_ -match '^(target[_ ]?upn|target)$' } | Select-Object -First 1
        $noteCol = $props | Where-Object { $_ -match '^notes?$' } | Select-Object -First 1
        if (-not $srcCol) { continue }

        $sourceUpn = $rec.$srcCol
        if (-not $sourceUpn) { continue }
        $targetUpn = if ($tgtCol) { $rec.$tgtCol } else { $null }
        $notes = if ($noteCol) { $rec.$noteCol } else { $null }

        $src = Invoke-DbQuery -Query 'SELECT * FROM directory_users WHERE tenant = ''source'' AND lower(upn) = lower(@u) LIMIT 1;' -SqlParameters @{ u = $sourceUpn }
        $src = @($src) | Select-Object -First 1
        $tgt = Resolve-TargetByUpn -Upn $targetUpn
        $state = if (-not $targetUpn) { 'unmatched' } else { 'matched' }

        Save-Mapping -SourceUpn $sourceUpn -SourceId ($src.user_id) -SourceDisplay ($src.display_name) `
            -TargetUpn $targetUpn -TargetId ($tgt.user_id) -TargetDisplay ($tgt.display_name) `
            -TargetExists ([int][bool]$tgt) -State $state -Method 'csv' -Notes $notes
        $imported++
    }
    return @{ imported = $imported; summary = (Get-MappingSummary) }
}

function Export-MappingCsv {
    <#
    .SYNOPSIS
        Returns the current mappings as CSV text.
    #>
    [CmdletBinding()]
    param()
    $rows = Get-Mappings | ForEach-Object {
        [pscustomobject]@{
            SourceUpn         = $_.sourceUpn
            SourceDisplayName = $_.sourceDisplayName
            TargetUpn         = $_.targetUpn
            TargetDisplayName = $_.targetDisplayName
            TargetExists      = $_.targetExists
            MatchState        = $_.matchState
            MatchMethod       = $_.matchMethod
            Notes             = $_.notes
        }
    }
    return (($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n")
}

Export-ModuleMember -Function `
    Get-DirectoryUsers, Sync-DirectoryUsers, Get-CachedUsers, `
    Invoke-AutoMatch, Get-Mappings, Get-MappingSummary, Save-Mappings, `
    Import-MappingCsv, Export-MappingCsv

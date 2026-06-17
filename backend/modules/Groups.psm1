#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Group discovery + cross-tenant recreation with membership remap (Phase 9).
.DESCRIPTION
    There is no MRS-style move for a group object, so groups are RECREATED in the target and
    their membership repopulated by translating each source member through the identity
    mapping (mappings table). Security + Microsoft 365 groups are created via Graph (verified
    offline); distribution / mail-enabled-security groups need EXO New-DistributionGroup
    (guarded) and are flagged if unavailable. Recreating groups before SharePoint site moves
    is what lets group-based site permissions resolve in the target.

    Read (sync) is read-only; creation is a gated mutation. Depends on State.psm1, and
    membership remap needs the target directory cache (Mapping sync) + mappings.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')
function Test-GraphConfigured { param($T) $g = $T.graph; return (($script:Placeholders -notcontains $g.appId) -and ($script:Placeholders -notcontains $g.certThumbprint) -and ($script:Placeholders -notcontains $T.tenantId)) }

function Connect-TenantGraph {
    param($Tenant)
    Import-GraphModules
    Connect-MgGraph -ClientId $Tenant.graph.appId -TenantId $Tenant.tenantId -CertificateThumbprint $Tenant.graph.certThumbprint -NoWelcome -ErrorAction Stop
}
function Disconnect-Graph { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }

function Get-GroupKind {
    param($Group)
    $types = @($Group.GroupTypes)
    if ($types -contains 'Unified') { return 'm365' }
    if ($Group.MailEnabled -and $Group.SecurityEnabled) { return 'mailSecurity' }
    if ($Group.MailEnabled) { return 'distribution' }
    return 'security'
}

function Sync-SourceGroups {
    <#
    .SYNOPSIS
        Reads source groups + membership into the local cache (read-only).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    $src = $Config.tenants.source
    if (-not (Test-GraphConfigured $src)) { throw 'Graph is not configured for the source tenant.' }
    try {
        Connect-TenantGraph -Tenant $src
        $groups = @(Get-MgGroup -All -Property 'id,displayName,mailNickname,mail,groupTypes,securityEnabled,mailEnabled' -ErrorAction Stop)
        $now = [DateTime]::UtcNow.ToString('o')
        Invoke-DbQuery -Query 'DELETE FROM groups;' | Out-Null
        Invoke-DbQuery -Query 'DELETE FROM group_members;' | Out-Null
        foreach ($g in $groups) {
            $members = @()
            try { $members = @(Get-MgGroupMember -GroupId $g.Id -All -ErrorAction Stop) } catch { }
            $kind = Get-GroupKind $g
            Invoke-DbQuery -Query @'
INSERT INTO groups (group_id, display_name, mail_nickname, mail, group_kind, member_count, status, fetched_utc)
VALUES (@id,@dn,@mn,@mail,@k,@c,'discovered',@t);
'@ -SqlParameters @{ id = $g.Id; dn = $g.DisplayName; mn = $g.MailNickname; mail = $g.Mail; k = $kind; c = $members.Count; t = $now } | Out-Null
            foreach ($m in $members) {
                $upn = $null
                try { $upn = [string]$m.AdditionalProperties['userPrincipalName'] } catch { }
                Invoke-DbQuery -Query 'INSERT OR IGNORE INTO group_members (group_id, member_id, member_upn) VALUES (@g,@m,@u);' `
                    -SqlParameters @{ g = $g.Id; m = $m.Id; u = $upn } | Out-Null
            }
        }
        return @{ count = $groups.Count }
    }
    finally { Disconnect-Graph }
}

function Get-Groups {
    [CmdletBinding()] param()
    $rows = Invoke-DbQuery -Query 'SELECT * FROM groups ORDER BY display_name;'
    return @($rows) | ForEach-Object {
        [ordered]@{ groupId = $_.group_id; displayName = $_.display_name; mailNickname = $_.mail_nickname; kind = $_.group_kind; memberCount = $_.member_count; status = $_.status; targetGroupId = $_.target_group_id; detail = $_.detail }
    }
}

function Resolve-TargetMemberId {
    # source member upn -> mapped target upn -> target directory user id
    param([string]$SourceUpn)
    if (-not $SourceUpn) { return $null }
    $map = @(Invoke-DbQuery -Query 'SELECT target_upn FROM mappings WHERE lower(source_upn)=lower(@u) AND target_upn IS NOT NULL;' -SqlParameters @{ u = $SourceUpn }) | Select-Object -First 1
    if (-not $map) { return $null }
    $tu = @(Invoke-DbQuery -Query "SELECT user_id FROM directory_users WHERE tenant='target' AND lower(upn)=lower(@u);" -SqlParameters @{ u = $map.target_upn }) | Select-Object -First 1
    return ($(if ($tu) { $tu.user_id } else { $null }))
}

function New-TargetGroups {
    <#
    .SYNOPSIS
        GATED: recreates selected source groups in the target and remaps membership.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string[]]$GroupIds)
    $tgt = $Config.tenants.target
    if (-not (Test-GraphConfigured $tgt)) { throw 'Graph is not configured for the target tenant.' }

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        Connect-TenantGraph -Tenant $tgt
        foreach ($gid in $GroupIds) {
            $g = @(Invoke-DbQuery -Query 'SELECT * FROM groups WHERE group_id=@id;' -SqlParameters @{ id = $gid }) | Select-Object -First 1
            if (-not $g) { continue }
            $corr = New-CorrelationId
            if ($g.group_kind -in @('distribution', 'mailSecurity')) {
                Invoke-DbQuery -Query 'UPDATE groups SET status=''skipped'', detail=@d WHERE group_id=@id;' -SqlParameters @{ d = 'Distribution/mail-enabled-security groups require EXO New-DistributionGroup — create separately.'; id = $gid } | Out-Null
                $results.Add(@{ groupId = $gid; name = $g.display_name; status = 'skipped'; reason = 'needs EXO New-DistributionGroup' }); continue
            }
            try {
                $params = @{ DisplayName = $g.display_name; MailNickname = ($g.mail_nickname ?? ($g.display_name -replace '[^a-zA-Z0-9]', '')); SecurityEnabled = ($g.group_kind -eq 'security'); MailEnabled = ($g.group_kind -eq 'm365') }
                if ($g.group_kind -eq 'm365') { $params.GroupTypes = @('Unified') } else { $params.GroupTypes = @() }
                $new = New-MgGroup @params -ErrorAction Stop

                # Membership remap.
                $added = 0; $unmapped = 0
                foreach ($m in @(Invoke-DbQuery -Query 'SELECT member_upn FROM group_members WHERE group_id=@g;' -SqlParameters @{ g = $gid })) {
                    $tid = Resolve-TargetMemberId -SourceUpn $m.member_upn
                    if (-not $tid) { $unmapped++; continue }
                    try { New-MgGroupMember -GroupId $new.Id -DirectoryObjectId $tid -ErrorAction Stop; $added++ } catch { }
                }
                Invoke-DbQuery -Query 'UPDATE groups SET status=''created'', target_group_id=@tid, detail=@d WHERE group_id=@id;' `
                    -SqlParameters @{ tid = $new.Id; d = "members added=$added unmapped=$unmapped"; id = $gid } | Out-Null
                Add-AuditEntry -RunId $RunId -CorrelationId $corr -Action 'group.create' -Target $g.display_name -Detail "kind=$($g.group_kind) added=$added unmapped=$unmapped"
                $results.Add(@{ groupId = $gid; name = $g.display_name; status = 'created'; membersAdded = $added; unmapped = $unmapped })
            }
            catch {
                Invoke-DbQuery -Query 'UPDATE groups SET status=''failed'', detail=@d WHERE group_id=@id;' -SqlParameters @{ d = $_.Exception.Message; id = $gid } | Out-Null
                $results.Add(@{ groupId = $gid; name = $g.display_name; status = 'failed'; reason = $_.Exception.Message })
            }
        }
    }
    finally { Disconnect-Graph }
    return @{ results = $results }
}

Export-ModuleMember -Function Sync-SourceGroups, Get-Groups, New-TargetGroups, Resolve-TargetMemberId

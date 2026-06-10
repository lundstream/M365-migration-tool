#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Shared-mailbox delegate permission capture + reapply (Phase 9).
.DESCRIPTION
    Cross-tenant mailbox moves do NOT carry FullAccess / SendAs / SendOnBehalf delegate
    permissions. This module captures them from the source (read-only), then re-applies them
    on the target after the move, remapping every mailbox and trustee through the identity
    mapping. Shared mailboxes move like user mailboxes (they still need a target MailUser).

    GUARDRAIL #4: all EXO cmdlets are post-connect REST and guarded by Assert-CmdletReady.
    Depends on State.psm1 in the same runspace.
#>

$script:Placeholders = @($null, '', '00000000-0000-0000-0000-000000000000', 'REPLACE_WITH_CERT_THUMBPRINT')
function Test-ExoConfigured { param($T) $e = $T.exchangeOnline; return (($script:Placeholders -notcontains $e.appId) -and ($script:Placeholders -notcontains $e.certThumbprint) -and ($script:Placeholders -notcontains $e.organization)) }
function Connect-Exo { param($T) $e = $T.exchangeOnline; Import-Module ExchangeOnlineManagement -ErrorAction Stop; Connect-ExchangeOnline -AppId $e.appId -Organization $e.organization -CertificateThumbprint $e.certThumbprint -ShowBanner:$false -ShowProgress:$false -ErrorAction Stop }
function Disconnect-Exo { try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { } }
function Assert-CmdletReady {
    param([string]$Name, [string[]]$RequiredParameters = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Cmdlet '$Name' not available (not connected?). Verify before use (guardrail #4)." }
    $missing = @($RequiredParameters | Where-Object { $_ -notin @($cmd.Parameters.Keys) })
    if ($missing.Count -gt 0) { throw "Cmdlet '$Name' missing parameter(s): $($missing -join ', ') (guardrail #4)." }
}
function Resolve-TargetUpn { param([string]$SourceUpn) if (-not $SourceUpn) { return $null }; $m = @(Invoke-DbQuery -Query 'SELECT target_upn FROM mappings WHERE lower(source_upn)=lower(@u) AND target_upn IS NOT NULL;' -SqlParameters @{ u = $SourceUpn }) | Select-Object -First 1; return ($(if ($m) { $m.target_upn } else { $null })) }

function Get-SharedMailboxes {
    <#
    .SYNOPSIS
        Lists source shared mailboxes (read-only).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Config)
    $src = $Config.tenants.source
    if (-not (Test-ExoConfigured $src)) { throw 'Exchange Online is not configured for the source tenant.' }
    try {
        Connect-Exo -Tenant $src
        Assert-CmdletReady -Name 'Get-Mailbox' -RequiredParameters @('RecipientTypeDetails')
        return @(Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited -ErrorAction Stop |
            ForEach-Object { [ordered]@{ upn = [string]$_.PrimarySmtpAddress; displayName = [string]$_.DisplayName } })
    }
    finally { Disconnect-Exo }
}

function Save-MailboxPermissions {
    <#
    .SYNOPSIS
        Captures FullAccess / SendAs / SendOnBehalf for the given source mailboxes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string[]]$Mailboxes)
    $src = $Config.tenants.source
    if (-not (Test-ExoConfigured $src)) { throw 'Exchange Online is not configured for the source tenant.' }
    $now = [DateTime]::UtcNow.ToString('o')
    $captured = 0
    try {
        Connect-Exo -Tenant $src
        Assert-CmdletReady -Name 'Get-MailboxPermission' -RequiredParameters @('Identity')
        Assert-CmdletReady -Name 'Get-RecipientPermission' -RequiredParameters @('Identity')
        foreach ($mbx in $Mailboxes) {
            Invoke-DbQuery -Query 'DELETE FROM mailbox_permissions WHERE mailbox_upn=@m;' -SqlParameters @{ m = $mbx } | Out-Null
            # FullAccess
            try {
                foreach ($p in @(Get-MailboxPermission -Identity $mbx -ErrorAction Stop | Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited -and $_.User -notmatch 'NT AUTHORITY|S-1-5' })) {
                    Add-PermRow $mbx 'FullAccess' ([string]$p.User) $now; $captured++
                }
            } catch { }
            # SendAs
            try {
                foreach ($p in @(Get-RecipientPermission -Identity $mbx -ErrorAction Stop | Where-Object { $_.AccessRights -contains 'SendAs' -and $_.Trustee -notmatch 'NT AUTHORITY|S-1-5' })) {
                    Add-PermRow $mbx 'SendAs' ([string]$p.Trustee) $now; $captured++
                }
            } catch { }
            # SendOnBehalf
            try {
                $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
                foreach ($t in @($mb.GrantSendOnBehalfTo)) { Add-PermRow $mbx 'SendOnBehalf' ([string]$t) $now; $captured++ }
            } catch { }
        }
        Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action 'permissions.capture' -Target "$($Mailboxes.Count) mailbox(es)" -Detail "rows=$captured"
    }
    finally { Disconnect-Exo }
    return @{ captured = $captured; permissions = (Get-CapturedPermissions) }
}

function Add-PermRow {
    param([string]$Mbx, [string]$Type, [string]$Trustee, [string]$When)
    Invoke-DbQuery -Query 'INSERT INTO mailbox_permissions (mailbox_upn, perm_type, trustee_upn, captured_utc) VALUES (@m,@t,@tr,@w);' `
        -SqlParameters @{ m = $Mbx; t = $Type; tr = $Trustee; w = $When } | Out-Null
}

function Get-CapturedPermissions {
    [CmdletBinding()] param()
    $rows = Invoke-DbQuery -Query 'SELECT mailbox_upn, perm_type, trustee_upn, reapplied, reapply_error FROM mailbox_permissions ORDER BY mailbox_upn, perm_type;'
    return @($rows) | ForEach-Object { [ordered]@{ mailbox = $_.mailbox_upn; type = $_.perm_type; trustee = $_.trustee_upn; reapplied = [bool]$_.reapplied; error = $_.reapply_error } }
}

function Invoke-ReapplyPermissions {
    <#
    .SYNOPSIS
        GATED: re-applies captured permissions on the TARGET, remapping mailbox + trustee.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string]$RunId)
    $tgt = $Config.tenants.target
    if (-not (Test-ExoConfigured $tgt)) { throw 'Exchange Online is not configured for the target tenant.' }

    $rows = @(Invoke-DbQuery -Query 'SELECT id, mailbox_upn, perm_type, trustee_upn FROM mailbox_permissions WHERE reapplied=0;')
    $applied = 0; $skipped = 0
    try {
        Connect-Exo -Tenant $tgt
        Assert-CmdletReady -Name 'Add-MailboxPermission' -RequiredParameters @('Identity', 'User', 'AccessRights')
        Assert-CmdletReady -Name 'Add-RecipientPermission' -RequiredParameters @('Identity', 'Trustee', 'AccessRights')
        foreach ($r in $rows) {
            $tMbx = Resolve-TargetUpn -SourceUpn $r.mailbox_upn
            $tTrustee = Resolve-TargetUpn -SourceUpn $r.trustee_upn
            if (-not $tMbx -or -not $tTrustee) {
                Invoke-DbQuery -Query 'UPDATE mailbox_permissions SET reapply_error=@e WHERE id=@id;' -SqlParameters @{ e = 'mailbox or trustee not mapped to target'; id = $r.id } | Out-Null
                $skipped++; continue
            }
            try {
                switch ($r.perm_type) {
                    'FullAccess'   { Add-MailboxPermission -Identity $tMbx -User $tTrustee -AccessRights FullAccess -InheritanceType All -ErrorAction Stop | Out-Null }
                    'SendAs'       { Add-RecipientPermission -Identity $tMbx -Trustee $tTrustee -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null }
                    'SendOnBehalf' { Set-Mailbox -Identity $tMbx -GrantSendOnBehalfTo @{ Add = $tTrustee } -ErrorAction Stop | Out-Null }
                }
                Invoke-DbQuery -Query 'UPDATE mailbox_permissions SET reapplied=1, reapply_error=NULL WHERE id=@id;' -SqlParameters @{ id = $r.id } | Out-Null
                Add-AuditEntry -RunId $RunId -CorrelationId (New-CorrelationId) -Action "permissions.reapply.$($r.perm_type)" -Target $tMbx -Detail "trustee=$tTrustee"
                $applied++
            }
            catch { Invoke-DbQuery -Query 'UPDATE mailbox_permissions SET reapply_error=@e WHERE id=@id;' -SqlParameters @{ e = $_.Exception.Message; id = $r.id } | Out-Null }
        }
    }
    finally { Disconnect-Exo }
    return @{ applied = $applied; skipped = $skipped; permissions = (Get-CapturedPermissions) }
}

Export-ModuleMember -Function Get-SharedMailboxes, Save-MailboxPermissions, Get-CapturedPermissions, Invoke-ReapplyPermissions

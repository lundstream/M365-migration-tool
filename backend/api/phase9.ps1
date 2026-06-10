# Phase 9 routes: pre-migration manifest, groups, shared-mailbox permissions.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# ---------------- Manifest ----------------

Add-PodeRoute -Method Get -Path '/api/manifest' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $m = Get-Manifest
    Write-PodeJsonResponse -Value @{ manifests = (Get-Manifests); latest = $m } -Depth 14
}
Add-PodeRoute -Method Post -Path '/api/manifest/capture' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId; New-Run -RunId $runId -Kind 'manifest' -Notes 'Pre-migration inventory' | Out-Null
    try {
        $scope = if ($d -and $d.scope) { @($d.scope) } else { @('mailboxes', 'onedrive', 'sites') }
        Write-PodeJsonResponse -Value (New-Manifest -Config $config -RunId $runId -Scope $scope) -Depth 14
    }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}

# ---------------- Groups ----------------

Add-PodeRoute -Method Get -Path '/api/groups' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    Write-PodeJsonResponse -Value @{ groups = (Get-Groups) } -Depth 14
}
Add-PodeRoute -Method Post -Path '/api/groups/sync' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    try { Write-PodeJsonResponse -Value (Sync-SourceGroups -Config (Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json)) -Depth 8 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}
Add-PodeRoute -Method Post -Path '/api/groups/create' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId; New-Run -RunId $runId -Kind 'groups-create' -Notes 'Recreate groups in target' | Out-Null
    try { Write-PodeJsonResponse -Value (New-TargetGroups -Config $config -RunId $runId -GroupIds @($d.groupIds)) -Depth 14 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}

# ---------------- Shared-mailbox permissions ----------------

Add-PodeRoute -Method Get -Path '/api/permissions' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    Write-PodeJsonResponse -Value @{ permissions = (Get-CapturedPermissions) } -Depth 14
}
Add-PodeRoute -Method Get -Path '/api/permissions/shared-mailboxes' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    try { Write-PodeJsonResponse -Value @{ mailboxes = (Get-SharedMailboxes -Config (Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json)) } -Depth 8 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}
Add-PodeRoute -Method Post -Path '/api/permissions/capture' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId; New-Run -RunId $runId -Kind 'permissions-capture' -Notes 'Capture mailbox permissions' | Out-Null
    try { Write-PodeJsonResponse -Value (Save-MailboxPermissions -Config $config -RunId $runId -Mailboxes @($d.mailboxes)) -Depth 14 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}
Add-PodeRoute -Method Post -Path '/api/permissions/reapply' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId; New-Run -RunId $runId -Kind 'permissions-reapply' -Notes 'Reapply mailbox permissions on target' | Out-Null
    try { Write-PodeJsonResponse -Value (Invoke-ReapplyPermissions -Config $config -RunId $runId) -Depth 14 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}

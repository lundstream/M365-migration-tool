# Migration setup routes (Phase 4 — gated mutations). DETECT-then-CREATE the cross-tenant
# prerequisites. Status is read-only; create requires explicit confirmation.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/migration-setup/status — detect all three prerequisites (read-only).
Add-PodeRoute -Method Get -Path '/api/migration-setup/status' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    try {
        $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
        Write-PodeJsonResponse -Value (Get-MigrationSetupStatus -Config $config) -Depth 12
    }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500 }
}

# POST /api/migration-setup/create — GATED create of one prerequisite.
# Body: { item: 'endpoint'|'orgRelationship'|'spoRelationship', confirm: true }
Add-PodeRoute -Method Post -Path '/api/migration-setup/create' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }
    if ($d.item -notin @('endpoint', 'orgRelationship', 'spoRelationship')) {
        Write-PodeJsonResponse -Value @{ error = "Unknown item '$($d.item)'." } -StatusCode 400; return
    }

    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'migration-setup' -Notes "Create $($d.item)" | Out-Null
    Write-JsonLog -RunId $runId -Level Information -Message 'Migration setup create' -Data @{ item = $d.item }
    try {
        $result = Invoke-MigrationSetupCreate -Config $config -RunId $runId -Item $d.item
        Write-JsonLog -RunId $runId -Level Information -Message 'Migration setup result' -Data @{ item = $d.item; status = $result.status }
        Write-PodeJsonResponse -Value @{ runId = $runId; result = $result } -Depth 12
    }
    catch {
        Write-JsonLog -RunId $runId -Level Error -Message 'Migration setup failed' -Data @{ error = $_.Exception.Message }
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 500
    }
}

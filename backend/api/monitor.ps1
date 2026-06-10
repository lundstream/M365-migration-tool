# Monitoring routes (Phase 7). GET = cheap normalized model (poll this); POST refresh =
# expensive live reconcile with the cloud.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/monitor — normalized progress model from persisted state (cheap).
Add-PodeRoute -Method Get -Path '/api/monitor' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    Write-PodeJsonResponse -Value (Get-MonitorModel) -Depth 14
}

# POST /api/monitor/refresh — live poll of active batches + file moves, then return the model.
Add-PodeRoute -Method Post -Path '/api/monitor/refresh' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    try { Write-PodeJsonResponse -Value (Invoke-MonitorRefresh -Config $config) -Depth 14 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}

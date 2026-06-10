# Connection manager routes (Phase 1, read-only against tenants).
# Each scriptblock runs in its own Pode runspace, so it dot-sources the bootstrap to
# load backend modules + attach to the DB before doing work.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/connections — redacted (secret-free) connection config.
Add-PodeRoute -Method Get -Path '/api/connections' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap)
    . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    Write-PodeJsonResponse -Value (Get-ConnectionConfigSafe -Config $config) -Depth 12
}

# PUT /api/connections — persist NON-SECRET connection fields to config.json.
Add-PodeRoute -Method Put -Path '/api/connections' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap)
    . $bootstrap
    # config.json lives next to config.example.json under <repo>/config
    $repoRoot = Split-Path $env:MIG_BACKEND_DIR -Parent
    $targetPath = Join-Path $repoRoot 'config\config.json'

    $corr = New-CorrelationId
    $safe = Save-ConnectionConfig -ConfigPath $targetPath -Update $WebEvent.Data
    Add-AuditEntry -CorrelationId $corr -Action 'connections.config.save' -Target 'config.json' `
        -Detail 'Updated non-secret connection settings'
    Write-PodeJsonResponse -Value @{ saved = $true; correlationId = $corr; config = $safe } -Depth 12
}

# GET /api/connections/health — probe Graph/EXO/SPO for both tenants.
Add-PodeRoute -Method Get -Path '/api/connections/health' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap)
    . $bootstrap
    $runId = (Get-PodeState -Name 'app').RunId
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $health = Get-ConnectionHealth -Config $config

    $summary = foreach ($t in $health.tenants) {
        foreach ($s in $t.services) { "$($t.tenant)/$($s.service)=$($s.status)" }
    }
    Write-JsonLog -RunId $runId -Level Information -Message 'Connection health probed' `
        -Data @{ results = ($summary -join '; ') }

    Write-PodeJsonResponse -Value $health -Depth 12
}

# Identity mapping routes (Phase 2). Read-only against tenants; writes local cache + mappings.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/mapping — current mappings + summary counts.
Add-PodeRoute -Method Get -Path '/api/mapping' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    Write-PodeJsonResponse -Value (Get-MappingSummary) -Depth 12
}

# GET /api/mapping/users/:tenant — cached directory users for a tenant.
Add-PodeRoute -Method Get -Path '/api/mapping/users/:tenant' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $tenant = $WebEvent.Parameters['tenant']
    Write-PodeJsonResponse -Value @{ tenant = $tenant; users = (Get-CachedUsers -Tenant $tenant) } -Depth 12
}

# POST /api/mapping/sync/:tenant — pull users from Graph into the local cache.
Add-PodeRoute -Method Post -Path '/api/mapping/sync/:tenant' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $tenant = $WebEvent.Parameters['tenant']
    $runId = (Get-PodeState -Name 'app').RunId
    try {
        $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
        $res = Sync-DirectoryUsers -Tenant $tenant -Config $config
        Write-JsonLog -RunId $runId -Level Information -Message 'Directory sync' -Data $res
        Write-PodeJsonResponse -Value $res -Depth 12
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400
    }
}

# POST /api/mapping/automatch — auto-match cached users (UPN + proxyAddresses).
Add-PodeRoute -Method Post -Path '/api/mapping/automatch' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    try {
        Write-PodeJsonResponse -Value (Invoke-AutoMatch) -Depth 12
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400
    }
}

# PUT /api/mapping — save operator edits (manual target assignment).
Add-PodeRoute -Method Put -Path '/api/mapping' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $rows = $WebEvent.Data.rows
    Write-PodeJsonResponse -Value (Save-Mappings -Rows $rows) -Depth 12
}

# POST /api/mapping/import — import explicit mapping from CSV text.
Add-PodeRoute -Method Post -Path '/api/mapping/import' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    try {
        Write-PodeJsonResponse -Value (Import-MappingCsv -Csv $WebEvent.Data.csv) -Depth 12
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400
    }
}

# GET /api/mapping/export — download current mappings as CSV.
Add-PodeRoute -Method Get -Path '/api/mapping/export' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $csv = Export-MappingCsv
    Add-PodeHeader -Name 'Content-Disposition' -Value 'attachment; filename="mappings.csv"'
    Write-PodeTextResponse -Value $csv -ContentType 'text/csv'
}

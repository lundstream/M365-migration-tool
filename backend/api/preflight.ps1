# Preflight routes (Phase 3). Read-only against tenants; persists results to SQLite.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# POST /api/preflight/run — run the full preflight over the current mapping set.
Add-PodeRoute -Method Post -Path '/api/preflight/run' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'preflight' -Notes 'Read-only preflight validation' | Out-Null
    Write-JsonLog -RunId $runId -Level Information -Message 'Preflight started'
    try {
        $report = Invoke-Preflight -Config $config -RunId $runId
        Write-JsonLog -RunId $runId -Level Information -Message 'Preflight complete' `
            -Data @{ pass = $report.pass; warn = $report.warn; block = $report.block }
        Write-PodeJsonResponse -Value $report -Depth 12
    }
    catch {
        Write-JsonLog -RunId $runId -Level Error -Message 'Preflight failed' -Data @{ error = $_.Exception.Message }
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 500
    }
}

# GET /api/preflight/latest — most recent preflight report.
Add-PodeRoute -Method Get -Path '/api/preflight/latest' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $report = Get-PreflightRun
    if (-not $report) { Write-PodeJsonResponse -Value @{ empty = $true }; return }
    Write-PodeJsonResponse -Value $report -Depth 12
}

# GET /api/preflight/export/:file — download report as HTML or CSV (file = <runId>.html|csv).
Add-PodeRoute -Method Get -Path '/api/preflight/export/:file' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $file = $WebEvent.Parameters['file']
    $runId = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $ext = [System.IO.Path]::GetExtension($file).TrimStart('.').ToLowerInvariant()
    $report = Get-PreflightRun -RunId $runId
    if (-not $report) { Write-PodeJsonResponse -Value @{ error = 'run not found' } -StatusCode 404; return }

    if ($ext -eq 'csv') {
        Add-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=`"preflight-$runId.csv`""
        Write-PodeTextResponse -Value (ConvertTo-PreflightCsv -Report $report) -ContentType 'text/csv'
    }
    else {
        Add-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=`"preflight-$runId.html`""
        Write-PodeTextResponse -Value (ConvertTo-PreflightHtml -Report $report) -ContentType 'text/html'
    }
}

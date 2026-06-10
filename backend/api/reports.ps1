# Reporting routes (Phase 8). Read-only over SQLite + JSONL. CSV / self-contained HTML export.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/reports/:name — runs | audit | status | failures | reconciliation
Add-PodeRoute -Method Get -Path '/api/reports/:name' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $name = $WebEvent.Parameters['name']
    if ($name -notin @('runs', 'audit', 'status', 'failures', 'reconciliation')) {
        Write-PodeJsonResponse -Value @{ error = "Unknown report '$name'." } -StatusCode 404; return
    }
    $runId = $WebEvent.Query['runId']
    Write-PodeJsonResponse -Value (Get-Report -Name $name -RunId $runId) -Depth 14
}

# GET /api/reports/export/:file  (file = <name>.csv | <name>.html)
Add-PodeRoute -Method Get -Path '/api/reports/export/:file' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $file = $WebEvent.Parameters['file']
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $ext = [System.IO.Path]::GetExtension($file).TrimStart('.').ToLowerInvariant()
    if ($name -notin @('runs', 'audit', 'status', 'failures', 'reconciliation')) {
        Write-PodeJsonResponse -Value @{ error = "Unknown report '$name'." } -StatusCode 404; return
    }
    $report = Get-Report -Name $name -RunId $WebEvent.Query['runId']
    if ($ext -eq 'csv') {
        Add-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=`"$name.csv`""
        Write-PodeTextResponse -Value (ConvertTo-ReportCsv -Report $report) -ContentType 'text/csv'
    }
    else {
        Add-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=`"$name.html`""
        Write-PodeTextResponse -Value (ConvertTo-ReportHtml -Report $report) -ContentType 'text/html'
    }
}

# Project report (PDF) + Swedish end-user manuals (Phase 10).

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/project/report/:ext  (ext = html | pdf)
Add-PodeRoute -Method Get -Path '/api/project/report/:ext' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $ext = ($WebEvent.Parameters['ext']).ToLowerInvariant()
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $html = Get-ProjectReportHtml -Config $config
    if ($ext -eq 'pdf') {
        try {
            $bytes = Convert-HtmlToPdf -Html $html
            Add-PodeHeader -Name 'Content-Disposition' -Value 'attachment; filename="migration-project-report.pdf"'
            Write-PodeTextResponse -Bytes $bytes -ContentType 'application/pdf'
        }
        catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
    }
    else {
        Write-PodeTextResponse -Value $html -ContentType 'text/html'
    }
}

# GET /api/project/manual/:file  (file = desktop.html | desktop.pdf | mobile.html | mobile.pdf)
Add-PodeRoute -Method Get -Path '/api/project/manual/:file' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $file = $WebEvent.Parameters['file']
    $which = [System.IO.Path]::GetFileNameWithoutExtension($file).ToLowerInvariant()
    $ext = [System.IO.Path]::GetExtension($file).TrimStart('.').ToLowerInvariant()
    if ($which -notin @('desktop', 'mobile')) { Write-PodeJsonResponse -Value @{ error = 'unknown manual' } -StatusCode 404; return }
    $html = Get-ManualHtml -Which $which
    if ($ext -eq 'pdf') {
        try {
            $bytes = Convert-HtmlToPdf -Html $html
            Add-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=`"anvandarguide-$which.pdf`""
            Write-PodeTextResponse -Bytes $bytes -ContentType 'application/pdf'
        }
        catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
    }
    else {
        Write-PodeTextResponse -Value $html -ContentType 'text/html'
    }
}

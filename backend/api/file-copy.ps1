# Copy-based OneDrive/SharePoint file migration routes. Source read-only; background thread.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

Add-PodeRoute -Method Get -Path '/api/file-copy/jobs' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    Write-PodeJsonResponse -Value @{ jobs = (Get-FileCopyJobs) } -Depth 12
}

Add-PodeRoute -Method Get -Path '/api/file-copy/jobs/:id' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $j = Get-FileCopyJob -JobId $WebEvent.Parameters['id']
    if (-not $j) { Write-PodeJsonResponse -Value @{ error = 'not found' } -StatusCode 404; return }
    Write-PodeJsonResponse -Value @{ job = $j } -Depth 12
}

# POST /api/file-copy/start — Body: { type: onedrive|site, source, target, confirm }
Add-PodeRoute -Method Post -Path '/api/file-copy/start' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Confirmation required.' } -StatusCode 400; return }
    if ($d.type -notin @('onedrive', 'site')) { Write-PodeJsonResponse -Value @{ error = "type must be onedrive or site." } -StatusCode 400; return }
    if (-not $d.source -or -not $d.target) { Write-PodeJsonResponse -Value @{ error = 'source and target are required.' } -StatusCode 400; return }
    $jobId = New-FileCopyJob -Type $d.type -Source $d.source -Target $d.target

    $worker = {
        param($backendDir, $dbPath, $logDir, $configPath, $jobId, $type, $src, $tgt)
        $env:MIG_BACKEND_DIR = $backendDir; $env:MIG_DB_PATH = $dbPath; $env:MIG_LOG_DIR = $logDir; $env:MIG_CONFIG_PATH = $configPath
        . (Join-Path $backendDir 'modules\_bootstrap.ps1')
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            Invoke-FileCopy -Config $config -JobId $jobId -Type $type -Source $src -Target $tgt | Out-Null
        }
        catch { try { Update-FileCopyJob -JobId $jobId -Set @{ status = 'failed'; error = $_.Exception.Message } } catch { } }
    }
    # Start-Job (separate process) so this copy's Graph auth context is isolated from any other
    # running copy — the Graph SDK keeps Connect-MgGraph state process-global. See mailbox-copy.ps1.
    Start-Job -ScriptBlock $worker -ArgumentList $env:MIG_BACKEND_DIR, $env:MIG_DB_PATH, $env:MIG_LOG_DIR, $env:MIG_CONFIG_PATH, $jobId, $d.type, $d.source, $d.target | Out-Null

    Write-PodeJsonResponse -Value @{ started = $true; jobId = $jobId } -Depth 8
}

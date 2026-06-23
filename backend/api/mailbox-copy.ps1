# Copy-based mailbox migration routes. Source read-only; runs in a background thread so the
# request returns immediately and the UI polls progress.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/mailbox-copy/jobs — list copy jobs.
Add-PodeRoute -Method Get -Path '/api/mailbox-copy/jobs' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    Write-PodeJsonResponse -Value @{ jobs = (Get-MailboxCopyJobs) } -Depth 12
}

# GET /api/mailbox-copy/jobs/:id — one job (progress).
Add-PodeRoute -Method Get -Path '/api/mailbox-copy/jobs/:id' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $j = Get-MailboxCopyJob -JobId $WebEvent.Parameters['id']
    if (-not $j) { Write-PodeJsonResponse -Value @{ error = 'not found' } -StatusCode 404; return }
    Write-PodeJsonResponse -Value @{ job = $j } -Depth 12
}

# POST /api/mailbox-copy/start — start a copy in the background. Body: { sourceUpn, targetUpn, scope?, confirm }
Add-PodeRoute -Method Post -Path '/api/mailbox-copy/start' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Confirmation required.' } -StatusCode 400; return }
    if (-not $d.sourceUpn -or -not $d.targetUpn) { Write-PodeJsonResponse -Value @{ error = 'sourceUpn and targetUpn are required.' } -StatusCode 400; return }
    $scope = if ($d.scope) { [string]$d.scope } else { 'mail,calendar,contacts' }
    $jobId = New-MailboxCopyJob -SourceUpn $d.sourceUpn -TargetUpn $d.targetUpn -Scope $scope

    # Background worker: own runspace, re-bootstraps modules + DB, runs the copy, records errors.
    $worker = {
        param($backendDir, $dbPath, $logDir, $configPath, $jobId, $src, $tgt, $scope)
        $env:MIG_BACKEND_DIR = $backendDir; $env:MIG_DB_PATH = $dbPath; $env:MIG_LOG_DIR = $logDir; $env:MIG_CONFIG_PATH = $configPath
        . (Join-Path $backendDir 'modules\_bootstrap.ps1')
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            Invoke-MailboxCopy -Config $config -JobId $jobId -SourceUpn $src -TargetUpn $tgt -Scope $scope | Out-Null
        }
        catch {
            try { Update-CopyJob -JobId $jobId -Set @{ status = 'failed'; error = $_.Exception.Message } } catch { }
        }
    }
    Start-ThreadJob -ScriptBlock $worker -ArgumentList $env:MIG_BACKEND_DIR, $env:MIG_DB_PATH, $env:MIG_LOG_DIR, $env:MIG_CONFIG_PATH, $jobId, $d.sourceUpn, $d.targetUpn, $scope | Out-Null

    Write-PodeJsonResponse -Value @{ started = $true; jobId = $jobId } -Depth 8
}

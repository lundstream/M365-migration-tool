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
    # Start-Job (NOT Start-ThreadJob): runs in a SEPARATE PROCESS so each copy gets its own
    # Microsoft.Graph auth context. The Graph SDK stores Connect-MgGraph state in a process-global
    # singleton, so same-process concurrency would let jobs clobber each other's tenant connection.
    # Separate processes make concurrent copies (e.g. mail + OneDrive, or several users) safe.
    Start-Job -ScriptBlock $worker -ArgumentList $env:MIG_BACKEND_DIR, $env:MIG_DB_PATH, $env:MIG_LOG_DIR, $env:MIG_CONFIG_PATH, $jobId, $d.sourceUpn, $d.targetUpn, $scope | Out-Null

    Write-PodeJsonResponse -Value @{ started = $true; jobId = $jobId } -Depth 8
}

# POST /api/mailbox-copy/forwarding — cutover: set/clear source->target forwarding for matched
# users (gated mutation on the SOURCE tenant). Body: { sourceUpns?, keepCopy?, remove?, confirm }
Add-PodeRoute -Method Post -Path '/api/mailbox-copy/forwarding' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'mailbox-copy-forwarding' -Notes ($d.remove ? 'clear forwarding' : 'set forwarding') | Out-Null
    $p = @{ Config = $config; RunId = $runId }
    if ($d.sourceUpns) { $p.SourceUpns = @($d.sourceUpns) }
    if ($null -ne $d.keepCopy) { $p.KeepCopy = [bool]$d.keepCopy }
    if ($d.remove) { $p.Remove = $true }
    try { Write-PodeJsonResponse -Value (Set-MappingForwarding @p) -Depth 12 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}

# GET /api/mailbox-copy/forwarding-policy — read source tenant outbound auto-forwarding mode.
Add-PodeRoute -Method Get -Path '/api/mailbox-copy/forwarding-policy' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    try { Write-PodeJsonResponse -Value (Get-OutboundForwardingMode -Config $config) -Depth 8 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}

# POST /api/mailbox-copy/forwarding-policy — set it (default On = allow external forwarding). Gated.
Add-PodeRoute -Method Post -Path '/api/mailbox-copy/forwarding-policy' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'exo-outbound-forwarding' -Notes "AutoForwardingMode=$($d.mode)" | Out-Null
    $mode = if ($d.mode) { [string]$d.mode } else { 'On' }
    try { Write-PodeJsonResponse -Value (Set-OutboundForwardingMode -Config $config -RunId $runId -Mode $mode) -Depth 8 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}

# Mailbox batch executor routes (Phase 5 — DESTRUCTIVE on complete).
# create/start = sync only; complete = gated, type-to-confirm, all-synced required.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/mailbox/batches — list batches.
Add-PodeRoute -Method Get -Path '/api/mailbox/batches' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    Write-PodeJsonResponse -Value @{ batches = (Get-MailboxBatches) } -Depth 12
}

# GET /api/mailbox/batches/:id — batch detail (persisted state).
Add-PodeRoute -Method Get -Path '/api/mailbox/batches/:id' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $b = Get-MailboxBatch -BatchId $WebEvent.Parameters['id']
    if (-not $b) { Write-PodeJsonResponse -Value @{ error = 'not found' } -StatusCode 404; return }
    $ready = Test-BatchReadyToComplete -BatchId $b.batchId
    Write-PodeJsonResponse -Value @{ batch = $b; readyToComplete = $ready } -Depth 12
}

# POST /api/mailbox/batches — create + start a batch (SYNC ONLY). Body: { name, items:[{sourceUpn,targetUpn}], confirm }
Add-PodeRoute -Method Post -Path '/api/mailbox/batches' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'mailbox-batch-create' -Notes "Create batch $($d.name)" | Out-Null
    try {
        $b = New-MailboxBatch -Config $config -RunId $runId -Name $d.name -Items @($d.items)
        Write-JsonLog -RunId $runId -Level Information -Message 'Batch created (sync only)' -Data @{ batchId = $b.batchId; items = $b.itemCount }
        Write-PodeJsonResponse -Value @{ runId = $runId; batch = $b } -Depth 12
    }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}

# POST /api/mailbox/batches/:id/refresh — reconcile with live EXO (resume-safe).
Add-PodeRoute -Method Post -Path '/api/mailbox/batches/:id/refresh' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    try { Write-PodeJsonResponse -Value (Update-MailboxBatchStatus -Config $config -BatchId $WebEvent.Parameters['id']) -Depth 12 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}

# POST /api/mailbox/batches/:id/forwarding — set source->target forwarding (gated mutation).
Add-PodeRoute -Method Post -Path '/api/mailbox/batches/:id/forwarding' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'mailbox-forwarding' -Notes "Forwarding for $($WebEvent.Parameters['id'])" | Out-Null
    try { Write-PodeJsonResponse -Value (Set-SourceForwarding -Config $config -RunId $runId -BatchId $WebEvent.Parameters['id']) -Depth 12 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}

# POST /api/mailbox/batches/:id/complete — DESTRUCTIVE finalize. Body: { confirm, confirmToken }
Add-PodeRoute -Method Post -Path '/api/mailbox/batches/:id/complete' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm -or -not $d.confirmToken) { Write-PodeJsonResponse -Value @{ error = 'Completion requires confirm=true and confirmToken (the batch name).' } -StatusCode 400; return }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'mailbox-batch-complete' -Notes "DESTRUCTIVE complete $($WebEvent.Parameters['id'])" | Out-Null
    try {
        $b = Complete-MailboxBatch -Config $config -RunId $runId -BatchId $WebEvent.Parameters['id'] -ConfirmToken $d.confirmToken
        Write-PodeJsonResponse -Value @{ runId = $runId; batch = $b } -Depth 12
    }
    catch {
        Write-JsonLog -RunId $runId -Level Error -Message 'Batch complete refused/failed' -Data @{ error = $_.Exception.Message }
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 409
    }
}

# OneDrive + SharePoint cross-tenant content move routes (Phase 6).
# One-and-done: a source can only be moved once (enforced in the module). Validate first.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/file-move/jobs — list all move jobs.
Add-PodeRoute -Method Get -Path '/api/file-move/jobs' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    Write-PodeJsonResponse -Value @{ jobs = (Get-FileMoveJobs) } -Depth 12
}

# GET /api/file-move/sites/source — list source sites for the picker (read-only).
Add-PodeRoute -Method Get -Path '/api/file-move/sites/source' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    try {
        $sites = Get-SourceSites -Config $config
        foreach ($s in $sites) { $s.targetUrl = (Get-DerivedTargetUrl -Config $config -SourceUrl $s.url) }
        Write-PodeJsonResponse -Value @{ sites = $sites } -Depth 12
    }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}

# POST /api/file-move/site-migrate — picked-site flow. Body: { sourceUrl, action, confirm?, preferredBegin?, preferredEnd? }
# action = provision | validate | migrate (provision + migrate require confirm).
Add-PodeRoute -Method Post -Path '/api/file-move/site-migrate' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if ($d.action -in @('provision', 'migrate') -and -not $d.confirm) {
        Write-PodeJsonResponse -Value @{ error = 'This action mutates the target — confirm required.' } -StatusCode 400; return
    }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId; New-Run -RunId $runId -Kind 'site-migrate' -Notes "$($d.action) $($d.sourceUrl)" | Out-Null
    $p = @{ Config = $config; RunId = $runId; SourceUrl = $d.sourceUrl; Action = $d.action }
    if ($d.preferredBegin) { $p.PreferredBegin = [datetime]$d.preferredBegin }
    if ($d.preferredEnd) { $p.PreferredEnd = [datetime]$d.preferredEnd }
    try { Write-PodeJsonResponse -Value (Invoke-SiteMigration @p) -Depth 12 }
    catch { Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message; runId = $runId } -StatusCode 400 }
}

# POST /api/file-move/validate — read-only pre-move validation. Body: { type, source, target }
Add-PodeRoute -Method Post -Path '/api/file-move/validate' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    try { Write-PodeJsonResponse -Value (Test-FileMove -Config $config -Type $d.type -Source $d.source -Target $d.target) -Depth 12 }
    catch { Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message } -StatusCode 400 }
}

# POST /api/file-move/start — start one or more moves (one-and-done). Body:
# { type, items:[{source,target}], preferredBegin?, preferredEnd?, confirm }
Add-PodeRoute -Method Post -Path '/api/file-move/start' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'file-move' -Notes "Start $($d.type) moves" | Out-Null

    $begin = $null; $end = $null
    if ($d.preferredBegin) { $begin = [datetime]$d.preferredBegin }
    if ($d.preferredEnd) { $end = [datetime]$d.preferredEnd }

    $results = @()
    foreach ($it in @($d.items)) {
        $p = @{ Config = $config; RunId = $runId; Type = $d.type; Source = $it.source; Target = $it.target }
        if ($begin) { $p.PreferredBegin = $begin }
        if ($end) { $p.PreferredEnd = $end }
        try { $results += @{ source = $it.source; ok = $true; job = (Start-FileMove @p) } }
        catch { $results += @{ source = $it.source; ok = $false; error = $_.Exception.Message } }
    }
    Write-JsonLog -RunId $runId -Level Information -Message 'File moves started' -Data @{ type = $d.type; count = @($d.items).Count }
    Write-PodeJsonResponse -Value @{ runId = $runId; results = $results } -Depth 12
}

# POST /api/file-move/jobs/:id/refresh — poll move state.
Add-PodeRoute -Method Post -Path '/api/file-move/jobs/:id/refresh' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    try { Write-PodeJsonResponse -Value (Update-FileMoveState -Config $config -JobId $WebEvent.Parameters['id']) -Depth 12 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}

# POST /api/file-move/jobs/:id/stop — stop an in-progress move.
Add-PodeRoute -Method Post -Path '/api/file-move/jobs/:id/stop' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $runId = New-RunId
    New-Run -RunId $runId -Kind 'file-move-stop' -Notes "Stop $($WebEvent.Parameters['id'])" | Out-Null
    try { Write-PodeJsonResponse -Value (Stop-FileMove -Config $config -RunId $runId -JobId $WebEvent.Parameters['id']) -Depth 12 }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}

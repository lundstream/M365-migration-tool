# Target MailUser provisioning routes (first mutating feature).
# preview = read-only dry run; execute = GATED mutation creating MailUsers in the target.

$bootstrap = Join-Path $env:MIG_BACKEND_DIR 'modules\_bootstrap.ps1'

# GET /api/provisioning/domains — target verified domains for building new UPNs.
Add-PodeRoute -Method Get -Path '/api/provisioning/domains' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    try {
        $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
        Write-PodeJsonResponse -Value @{ domains = (Get-TargetDomains -Config $config) } -Depth 8
    }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}

# POST /api/provisioning/preview — read-only plan for the selected source users.
Add-PodeRoute -Method Post -Path '/api/provisioning/preview' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    try {
        $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
        $d = $WebEvent.Data
        $overrides = @{}
        if ($d.overrides) { $d.overrides.PSObject.Properties | ForEach-Object { $overrides[$_.Name] = $_.Value } }
        $plan = Build-ProvisioningPlan -Config $config -SourceUpns @($d.sourceUpns) -TargetDomain $d.targetDomain -Overrides $overrides
        Write-PodeJsonResponse -Value @{ plan = $plan } -Depth 12
    }
    catch { Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 400 }
}

# POST /api/provisioning/execute — GATED: create MailUsers. Returns one-time passwords.
Add-PodeRoute -Method Post -Path '/api/provisioning/execute' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $config = Get-Content -LiteralPath $env:MIG_CONFIG_PATH -Raw | ConvertFrom-Json
    $d = $WebEvent.Data
    if (-not $d.confirm) { Write-PodeJsonResponse -Value @{ error = 'Missing explicit confirmation.' } -StatusCode 400; return }

    $runId = New-RunId
    New-Run -RunId $runId -Kind 'provisioning' -Notes "Create target MailUsers on $($d.targetDomain)" | Out-Null
    Write-JsonLog -RunId $runId -Level Information -Message 'Provisioning started' -Data @{ count = @($d.sourceUpns).Count; targetDomain = $d.targetDomain; passwordMode = $d.passwordMode }
    try {
        $overrides = @{}
        if ($d.overrides) { $d.overrides.PSObject.Properties | ForEach-Object { $overrides[$_.Name] = $_.Value } }
        $forceChange = $true
        if ($null -ne $d.forceChange) { $forceChange = [bool]$d.forceChange }
        $addToGroups = $false
        if ($null -ne $d.addToGroups) { $addToGroups = [bool]$d.addToGroups }

        $result = Invoke-Provisioning -Config $config -RunId $runId `
            -SourceUpns @($d.sourceUpns) -TargetDomain $d.targetDomain `
            -PasswordMode $d.passwordMode -SharedPassword $d.sharedPassword `
            -ForceChange $forceChange -AddToGroups $addToGroups -Overrides $overrides

        # Log counts only — never passwords.
        Write-JsonLog -RunId $runId -Level Information -Message 'Provisioning complete' -Data @{ created = $result.created; skipped = $result.skipped; failed = $result.failed }
        Write-PodeJsonResponse -Value $result -Depth 12
    }
    catch {
        Write-JsonLog -RunId $runId -Level Error -Message 'Provisioning failed' -Data @{ error = $_.Exception.Message }
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message; runId = $runId } -StatusCode 500
    }
}

# GET /api/provisioning/latest — last run summary (NO passwords).
Add-PodeRoute -Method Get -Path '/api/provisioning/latest' -ArgumentList $bootstrap -ScriptBlock {
    param($bootstrap); . $bootstrap
    $run = Get-ProvisioningRun
    if (-not $run) { Write-PodeJsonResponse -Value @{ empty = $true }; return }
    Write-PodeJsonResponse -Value $run -Depth 12
}

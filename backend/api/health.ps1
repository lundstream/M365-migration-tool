# Health route. Self-contained (no external module calls) so it is safe to run
# inside Pode's per-request runspace. Dot-sourced by server.ps1 at startup.

Add-PodeRoute -Method Get -Path '/api/health' -ScriptBlock {
    $state = (Get-PodeState -Name 'app')

    Write-PodeJsonResponse -Value @{
        status     = 'ok'
        service    = 'M365-migration-tool'
        version    = '0.1.0-phase0'
        timeUtc    = [DateTime]::UtcNow.ToString('o')
        powershell = $PSVersionTable.PSVersion.ToString()
        db         = $state.DbPath
        startedUtc = $state.StartedUtc
    }
}

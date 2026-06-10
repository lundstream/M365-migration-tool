#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Customer-facing project report (PDF) + Swedish end-user manuals (Phase 10).
.DESCRIPTION
    Aggregates the migration outcome into a print-ready HTML "what was done" report and
    converts it to PDF using a headless Chromium browser (Edge/Chrome on the box — no extra
    dependency). Also renders the Swedish end-user manuals as HTML/PDF.

    Depends on State.psm1, Reporting.psm1, Manifest.psm1 in the same runspace.
#>

function Get-HeadlessBrowser {
    foreach ($p in @(
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Convert-HtmlToPdf {
    <#
    .SYNOPSIS
        Renders HTML to PDF bytes via headless Edge/Chrome.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Html)
    $browser = Get-HeadlessBrowser
    if (-not $browser) { throw 'No Edge/Chrome found for PDF generation. Install Microsoft Edge, or use the HTML report and print to PDF.' }
    $base = Join-Path ([IO.Path]::GetTempPath()) ('mig-' + [guid]::NewGuid().ToString('N'))
    $htmlPath = "$base.html"; $pdfPath = "$base.pdf"
    Set-Content -LiteralPath $htmlPath -Value $Html -Encoding utf8
    try {
        $fileUri = 'file:///' + ($htmlPath -replace '\\', '/')
        $args = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
            "--print-to-pdf=$pdfPath", '--print-to-pdf-no-header', $fileUri)
        Start-Process -FilePath $browser -ArgumentList $args -Wait -WindowStyle Hidden
        if (-not (Test-Path $pdfPath)) { throw 'PDF generation did not produce output.' }
        return , ([IO.File]::ReadAllBytes($pdfPath))
    }
    finally { Remove-Item $htmlPath, $pdfPath -Force -ErrorAction SilentlyContinue }
}

function Get-ProjectReportHtml {
    <#
    .SYNOPSIS
        Aggregates the migration outcome into a print-ready HTML report.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Config)

    $project = if ($Config.PSObject.Properties.Name -contains 'project') { $Config.project } else { $null }
    $customer = if ($project -and $project.customerName) { $project.customerName } else { 'Customer' }
    $projName = if ($project -and $project.projectName) { $project.projectName } else { 'Cross-tenant migration' }

    $recon = Get-ReconciliationReport
    $runs = Get-RunsReport
    $fails = Get-FailuresReport
    $manifest = Get-Manifest
    $auditCount = (@(Invoke-DbQuery -Query 'SELECT COUNT(*) AS c FROM audit_log;') | Select-Object -First 1).c

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    function Table($columns, $rows) {
        if (@($rows).Count -eq 0) { return '<p class="muted">None.</p>' }
        $h = ($columns | ForEach-Object { "<th>$(& $enc $_)</th>" }) -join ''
        $b = ($rows | ForEach-Object { $r = $_; '<tr>' + (($columns | ForEach-Object { "<td>$(& $enc $r[$_])</td>" }) -join '') + '</tr>' }) -join "`n"
        return "<table><thead><tr>$h</tr></thead><tbody>$b</tbody></table>"
    }

    $rs = $recon.summary
    $mfRow = if ($manifest) { "$($manifest.mailboxCount) mailboxes, $($manifest.oneDriveCount) OneDrive, $($manifest.siteCount) sites (snapshot $($manifest.createdUtc))" } else { 'No pre-migration manifest captured.' }

    return @"
<!doctype html><html><head><meta charset="utf-8"><title>Migration report — $(& $enc $customer)</title>
<style>
@page { margin: 18mm; }
body{font-family:'Segoe UI',system-ui,sans-serif;color:#1a1a1a;font-size:12px}
h1{font-size:20px;margin:0} h2{font-size:14px;border-bottom:2px solid #2563eb;padding-bottom:3px;margin-top:22px}
.cover{margin-bottom:8px} .meta{color:#555}
.cards{display:flex;gap:10px;margin:10px 0;flex-wrap:wrap}
.kpi{border:1px solid #ddd;border-radius:8px;padding:8px 14px;min-width:110px}
.kpi b{display:block;font-size:22px} .kpi.ok b{color:#1e8e3e} .kpi.warn b{color:#b06f00} .kpi.err b{color:#c5221f}
table{border-collapse:collapse;width:100%;font-size:11px;margin-top:6px}
th,td{border:1px solid #ddd;padding:3px 6px;text-align:left;vertical-align:top}
th{background:#f5f5f5} .muted{color:#777}
</style></head><body>
<div class="cover">
  <h1>Cross-tenant migration — project report</h1>
  <div class="meta">$(& $enc $customer) &middot; $(& $enc $projName) &middot; generated $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm')) UTC</div>
</div>

<h2>Executive summary</h2>
<div class="cards">
  <div class="kpi"><b>$($rs.intended)</b>intended users</div>
  <div class="kpi ok"><b>$($rs.reconciled)</b>reconciled</div>
  <div class="kpi warn"><b>$($rs.inProgress)</b>in progress</div>
  <div class="kpi"><b>$($rs.pending)</b>pending</div>
  <div class="kpi err"><b>$($rs.failed)</b>failed</div>
</div>
<p>Pre-migration inventory: $(& $enc $mfRow)<br/>Mutating actions recorded in the audit trail: <b>$auditCount</b>.</p>

<h2>Post-migration reconciliation</h2>
$(Table $recon.columns $recon.rows)

<h2>Runs</h2>
$(Table $runs.columns $runs.rows)

<h2>Failures</h2>
$(Table $fails.columns $fails.rows)

<p class="muted" style="margin-top:24px">Generated by the M365 cross-tenant migration tool. This report summarises orchestration outcomes; it is not a content backup. The authoritative record of pre-migration state is the captured manifest.</p>
</body></html>
"@
}

# ---------------- Swedish end-user manuals ----------------

function Get-ManualHtml {
    [CmdletBinding()] param([Parameter(Mandatory)][ValidateSet('desktop', 'mobile')][string]$Which)
    $css = @"
<style>
@page { margin: 16mm; }
body{font-family:'Segoe UI',system-ui,sans-serif;color:#1a1a1a;line-height:1.5;max-width:800px;margin:1.5rem auto;padding:0 1rem}
h1{font-size:22px} h2{font-size:16px;margin-top:1.4rem;border-bottom:1px solid #ddd;padding-bottom:3px}
ol{margin:.3rem 0 .8rem 1.2rem} li{margin:.25rem 0}
.note{background:#fff7e6;border:1px solid #f0c36d;border-radius:8px;padding:.6rem .9rem;margin:.8rem 0}
code{background:#eee;padding:1px 5px;border-radius:4px}
</style>
"@
    if ($Which -eq 'desktop') {
        $body = @"
<h1>Byta till den nya Microsoft 365-miljön — dator (Windows & Mac)</h1>
<p>Din e-post, OneDrive och Teams flyttas till en ny Microsoft 365-organisation. Följ stegen
nedan <b>på din inflyttningsdag</b>. Du har fått en <b>ny e-postadress</b> och ett
<b>tillfälligt lösenord</b> som du byter vid första inloggningen.</p>

<div class="note"><b>Innan du börjar:</b> spara öppet arbete och stäng Outlook, OneDrive och Teams.</div>

<h2>1. Logga ut från de gamla kontona</h2>
<ol>
<li><b>Windows:</b> Inställningar → Konton → Åtkomst till arbete eller skola → markera det gamla kontot → <b>Koppla från</b>.</li>
<li><b>Mac:</b> Systeminställningar → Internetkonton → ta bort det gamla Exchange-/Microsoft-kontot.</li>
<li>Öppna en webbläsare, gå till <code>office.com</code>, klicka på din profilbild → <b>Logga ut</b>. Stäng alla flikar.</li>
</ol>

<h2>2. Logga in med ditt nya konto</h2>
<ol>
<li>Gå till <code>portal.office.com</code> och logga in med din <b>nya e-postadress</b> och det <b>tillfälliga lösenordet</b>.</li>
<li>Byt lösenord när du uppmanas. Slutför ev. tvåfaktorsregistrering (MFA) med din telefon.</li>
</ol>

<h2>3. Outlook (e-post)</h2>
<ol>
<li>Öppna Outlook. Om den gamla profilen visas: <b>Arkiv → Kontoinställningar → Hantera profiler → Visa profiler → Lägg till</b> en ny profil och välj den vid start.</li>
<li>Lägg till ditt nya konto (din nya e-postadress). Låt Outlook bygga om postlådan — det kan ta en stund.</li>
<li>Mac: Outlook → Inställningar → Konton → <b>+</b> → lägg till det nya kontot, ta bort det gamla.</li>
</ol>

<h2>4. OneDrive</h2>
<ol>
<li>Starta OneDrive, logga in med det <b>nya</b> kontot.</li>
<li>Välj samma lokala mapp som tidigare om du blir tillfrågad. Filerna synkroniseras ned på nytt.</li>
<li>Kontrollera att molnikonerna blir gröna/blå innan du arbetar vidare.</li>
</ol>

<h2>5. Teams</h2>
<ol>
<li>Stäng Teams helt, starta igen och logga in med det nya kontot.</li>
<li>Klicka på din profilbild → kontrollera att rätt organisation visas.</li>
</ol>

<div class="note"><b>Vanliga frågor.</b> Saknas e-post eller filer direkt efter bytet? Vänta —
synkroniseringen tar tid. Kvarstår problem nästa dag, kontakta IT-supporten.</div>
"@
    }
    else {
        $body = @"
<h1>Byta till den nya Microsoft 365-miljön — mobil (iPhone & Android)</h1>
<p>Följ stegen för din telefon. Du behöver din <b>nya e-postadress</b> och ditt
<b>tillfälliga lösenord</b>.</p>

<h2>iPhone / iPad</h2>
<h3>Ta bort det gamla kontot</h3>
<ol>
<li>Inställningar → <b>Appar</b> → <b>Mail</b> → Konton (eller Inställningar → Kontakter → Konton).</li>
<li>Välj det gamla arbetskontot → <b>Radera konto</b>.</li>
<li>Har du Microsoft Outlook-appen: öppna den, gå till inställningar (kugghjul) → välj gamla kontot → <b>Ta bort konto</b>.</li>
</ol>
<h3>Lägg till det nya kontot</h3>
<ol>
<li>Installera/öppna <b>Microsoft Outlook</b> från App Store.</li>
<li>Lägg till konto → ange din <b>nya e-postadress</b> → det <b>tillfälliga lösenordet</b> → godkänn MFA.</li>
<li>Installera/öppna även <b>Teams</b> och <b>OneDrive</b> och logga in med det nya kontot.</li>
</ol>

<h2>Android</h2>
<h3>Ta bort det gamla kontot</h3>
<ol>
<li>Inställningar → <b>Konton</b> (eller Lösenord och konton) → välj det gamla arbetskontot → <b>Ta bort konto</b>.</li>
<li>I Outlook-appen: kugghjul → gamla kontot → <b>Ta bort konto</b>.</li>
</ol>
<h3>Lägg till det nya kontot</h3>
<ol>
<li>Öppna <b>Microsoft Outlook</b> → Lägg till konto → din <b>nya e-postadress</b> → <b>tillfälligt lösenord</b> → godkänn MFA.</li>
<li>Logga in i <b>Teams</b> och <b>OneDrive</b> med det nya kontot.</li>
</ol>

<div class="note"><b>Tips.</b> Om appen fortfarande visar gammal e-post: stäng appen helt och öppna
igen, eller starta om telefonen. Kvarstår problem, kontakta IT-supporten.</div>
"@
    }
    return "<!doctype html><html><head><meta charset=`"utf-8`"><title>Användarguide</title>$css</head><body>$body</body></html>"
}

Export-ModuleMember -Function Get-HeadlessBrowser, Convert-HtmlToPdf, Get-ProjectReportHtml, Get-ManualHtml

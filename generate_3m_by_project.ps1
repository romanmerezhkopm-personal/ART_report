# Rebuilds 3m.html as a Month -> Project -> Employee accordion (Roman's correction 14.08.2026:
# original structure was employee-first, he wanted project-first). Reads the already-collected
# time_share_3m_data.json snapshot - no new Asana API calls needed.
#
# All Russian UI text lives in labels_ru.json, loaded with -Encoding UTF8. This sidesteps the
# PowerShell 5.1 bug found earlier: literal Cyrillic typed directly into a .ps1 file gets corrupted
# because the script parser reads .ps1 source using the system ANSI codepage when there's no BOM.
# JSON files read via Get-Content -Encoding UTF8 do not have this problem - the encoding is explicit
# at read time. Do NOT add literal Cyrillic string constants directly in this script; add them to
# labels_ru.json instead.

$ErrorActionPreference = "Stop"
$BASE = "D:\project\weekly_ART_report"
$htmlFile   = "$BASE\3m.html"
$jsonFile   = "$BASE\time_share_3m_data.json"
$labelsFile = "$BASE\labels_ru.json"

$Start  = "2026-05-01"
$End    = "2026-07-31"
$Months = @("2026-05","2026-06","2026-07")

$PAT     = (Get-Content "$BASE\asana_pat.txt" -Raw).Trim()
$headers = @{ Authorization = "Bearer $PAT" }
$apiBase = "https://app.asana.com/api/1.0"

$labels = Get-Content $labelsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$dataObj = Get-Content $jsonFile -Raw -Encoding UTF8 | ConvertFrom-Json

# Live re-check of portfolio project count only (cheap, 1 call)
$PORTFOLIO_GID = "1213829329062998"
# Shared engine walks nested sub-portfolios (ART portfolio is nested since 07.10.2026). No try/catch
# with a hardcoded fallback count: a failed read must stop, not print a stale "13 projects" header.
. "D:\project\guardrails\asana_portfolio.ps1"
$portfolioProjCount = (Get-AsanaPortfolioProjects -PortfolioGid $PORTFOLIO_GID -RequestHeaders $headers).Count

function Esc([string]$s) { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
function Fmt([double]$h) { if ($h -eq [math]::Floor($h)) { "$([int]$h)" } else { "$([math]::Round($h,2))" } }
function MonthName([string]$mk) { $labels.monthNames.$mk }

$cappedNames = @('Ivan Monarkha','Roman Merezhko')  # hit exactly 100 tasks.search results in collection - see CONTEXT

# ------------------------------------------------------------
# 1. Team total time per month (denominator for project-level %)
# ------------------------------------------------------------
$teamMonthTotal = @{}
foreach ($mk in $Months) { $teamMonthTotal[$mk] = 0.0 }
$employeeMonthTotal = @{}   # "Name|2026-05" -> hours (denominator for employee-level %)
foreach ($prop in $dataObj.PSObject.Properties) {
    $name = $prop.Name
    foreach ($mk in $Months) {
        $mt = [double]$prop.Value.months.$mk.total / 60.0
        $teamMonthTotal[$mk] += $mt
        $employeeMonthTotal["$name|$mk"] = $mt
    }
}

# ------------------------------------------------------------
# 2. Month -> Project -> Employee hours (portfolio tasks only)
# ------------------------------------------------------------
$monthProjects = @{}
foreach ($mk in $Months) { $monthProjects[$mk] = @{} }
$vacationTaskCount = 0

foreach ($prop in $dataObj.PSObject.Properties) {
    $name = $prop.Name
    foreach ($tk in $prop.Value.tasks) {
        if ([string]$tk.project -like "*$($labels.vacationKeyword)*") { $vacationTaskCount++ }
        if (-not [bool]$tk.isPortfolio) { continue }
        $mk = [string]$tk.month
        if (-not $monthProjects.ContainsKey($mk)) { continue }
        $proj = [string]$tk.project
        if (-not $monthProjects[$mk].ContainsKey($proj)) {
            $monthProjects[$mk][$proj] = @{ hours = 0.0; employees = @{} }
        }
        $monthProjects[$mk][$proj].hours += [double]$tk.hours
        if (-not $monthProjects[$mk][$proj].employees.ContainsKey($name)) { $monthProjects[$mk][$proj].employees[$name] = 0.0 }
        $monthProjects[$mk][$proj].employees[$name] += [double]$tk.hours
    }
}

$portfolioEmployees = [System.Collections.Generic.HashSet[string]]::new()
foreach ($mk in $Months) { foreach ($proj in $monthProjects[$mk].Keys) { foreach ($e in $monthProjects[$mk][$proj].employees.Keys) { [void]$portfolioEmployees.Add($e) } } }

$teamTotalAll = 0.0; foreach ($mk in $Months) { $teamTotalAll += $teamMonthTotal[$mk] }
$teamTotalPortfolio = 0.0
foreach ($mk in $Months) { foreach ($proj in $monthProjects[$mk].Keys) { $teamTotalPortfolio += $monthProjects[$mk][$proj].hours } }
$teamOverallPct = if ($teamTotalAll -gt 0) { [math]::Round($teamTotalPortfolio / $teamTotalAll * 100, 1) } else { 0 }

$StartDisp = ([datetime]::ParseExact($Start,'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')
$EndDisp   = ([datetime]::ParseExact($End,  'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')

# ------------------------------------------------------------
# HTML
# ------------------------------------------------------------
$L = [System.Collections.Generic.List[string]]::new()
[void]$L.Add('<!DOCTYPE html>')
[void]$L.Add('<html lang="ru">')
[void]$L.Add('<head>')
[void]$L.Add('<meta charset="UTF-8">')
[void]$L.Add('<title>' + (Esc $labels.title) + '</title>')
[void]$L.Add('<style>')
[void]$L.Add('* { box-sizing:border-box; margin:0; padding:0; }')
[void]$L.Add('body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#f5f6fa; color:#2d3748; font-size:14px; }')
[void]$L.Add('.container { max-width:1100px; margin:0 auto; padding:24px; }')
[void]$L.Add('.header { background:linear-gradient(135deg,#667eea 0%,#764ba2 100%); color:white; border-radius:12px; padding:28px 32px; margin-bottom:24px; }')
[void]$L.Add('.header h1 { font-size:24px; font-weight:700; margin-bottom:6px; }')
[void]$L.Add('.header .meta { opacity:.85; font-size:13px; }')
[void]$L.Add('.header .stats { display:flex; gap:32px; margin-top:20px; flex-wrap:wrap; }')
[void]$L.Add('.stat { text-align:center; }')
[void]$L.Add('.stat-val { font-size:28px; font-weight:700; }')
[void]$L.Add('.stat-lbl { font-size:12px; opacity:.8; margin-top:2px; }')
[void]$L.Add('.notice-g { background:#f0fff4; border-left:4px solid #38a169; padding:12px 16px; border-radius:6px; margin-bottom:14px; font-size:13px; color:#276749; }')
[void]$L.Add('.notice-y { background:#fffbea; border-left:4px solid #d69e2e; padding:12px 16px; border-radius:6px; margin-bottom:24px; font-size:13px; color:#744210; }')
[void]$L.Add('.notice-y ul { margin:6px 0 0 18px; }')
[void]$L.Add('.warn-mark { color:#d69e2e; font-weight:700; cursor:help; }')
[void]$L.Add('details.month-block { margin-bottom:12px; background:white; border-radius:12px; box-shadow:0 1px 3px rgba(0,0,0,.08); overflow:hidden; }')
[void]$L.Add('details.month-block > summary { cursor:pointer; padding:18px 24px; background:linear-gradient(135deg,#667eea 0%,#764ba2 100%); color:white; font-weight:700; font-size:17px; list-style:none; display:flex; align-items:center; justify-content:space-between; }')
[void]$L.Add('details.month-block > summary::-webkit-details-marker { display:none; }')
[void]$L.Add('details.month-block > summary .sub { font-size:13px; font-weight:400; opacity:.9; margin-top:4px; display:block; }')
[void]$L.Add('details.month-block > summary::after { content:"\25B8"; font-size:16px; }')
[void]$L.Add('details.month-block[open] > summary::after { content:"\25BE"; }')
[void]$L.Add('.month-body { padding:16px 24px 20px; }')
[void]$L.Add('details.project-block { margin-bottom:8px; border:1px solid #e2e8f0; border-radius:8px; overflow:hidden; }')
[void]$L.Add('details.project-block > summary { cursor:pointer; padding:12px 16px; background:#f7f8fc; font-weight:600; font-size:14px; list-style:none; display:flex; align-items:center; justify-content:space-between; gap:16px; }')
[void]$L.Add('details.project-block > summary::-webkit-details-marker { display:none; }')
[void]$L.Add('details.project-block > summary::after { content:"\25B8"; color:#a0aec0; font-size:12px; }')
[void]$L.Add('details.project-block[open] > summary::after { content:"\25BE"; }')
[void]$L.Add('.proj-name { flex:1; }')
[void]$L.Add('.proj-metrics { display:flex; align-items:center; gap:14px; flex-shrink:0; }')
[void]$L.Add('.proj-bar-wrap { width:140px; background:#edf2f7; border-radius:4px; height:10px; }')
[void]$L.Add('.proj-bar { height:10px; border-radius:4px; background:#667eea; }')
[void]$L.Add('.proj-hours { font-weight:700; color:#2d3748; min-width:70px; text-align:right; }')
[void]$L.Add('.proj-pct { color:#718096; font-weight:600; min-width:56px; text-align:right; }')
[void]$L.Add('.emp-table { width:100%; border-collapse:collapse; }')
[void]$L.Add('.emp-table th { background:#f0f4f8; padding:8px 14px; text-align:left; font-size:11px; color:#718096; text-transform:uppercase; letter-spacing:.4px; }')
[void]$L.Add('.emp-table td { padding:8px 14px; border-bottom:1px solid #f0f2f7; font-size:13px; }')
[void]$L.Add('.emp-table tr:hover td { background:#f7f8fc; }')
[void]$L.Add('.emp-table .hours { font-weight:700; text-align:right; }')
[void]$L.Add('.emp-table .pct { color:#718096; font-weight:600; text-align:right; }')
[void]$L.Add('.total-row td { font-weight:700; background:#f7f8fc; }')
[void]$L.Add('.no-activity { color:#a0aec0; font-size:13px; padding:8px 0; }')
[void]$L.Add('</style>')
[void]$L.Add('</head>')
[void]$L.Add('<body><div class="container">')

# Header
[void]$L.Add('<div class="header">')
[void]$L.Add('  <h1>' + (Esc $labels.title) + '</h1>')
[void]$L.Add('  <div class="meta">' + (Esc $labels.period) + ': ' + $StartDisp + ' &#8212; ' + $EndDisp + ' &nbsp;|&nbsp; ' + (Esc $labels.portfolio) + ': ART Portfolio (' + $portfolioProjCount + ' ' + (Esc $labels.projectsWord) + ') &nbsp;|&nbsp; ' + (Esc $labels.team) + ': Art Team &nbsp;|&nbsp; ' + (Esc $labels.source) + ': Asana time_tracking_entries</div>')
[void]$L.Add('  <div class="stats">')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + (Fmt $teamTotalPortfolio) + '</div><div class="stat-lbl">' + (Esc $labels.statPortfolioHours) + '</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + (Fmt $teamTotalAll) + '</div><div class="stat-lbl">' + (Esc $labels.statTeamHours) + '</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $teamOverallPct + '%</div><div class="stat-lbl">' + (Esc $labels.statShare) + '</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $portfolioEmployees.Count + '</div><div class="stat-lbl">' + (Esc $labels.statEmployees) + '</div></div>')
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Notices
[void]$L.Add('<div class="notice-g">&#9989; ' + (Esc $labels.noticeMethod) + '</div>')
[void]$L.Add('<div class="notice-y">&#9888;&#65039; <strong>' + (Esc $labels.caveatsTitle) + '</strong>')
[void]$L.Add('  <ul>')
[void]$L.Add('    <li>' + (Esc $labels.caveatCapped) + '</li>')
[void]$L.Add('    <li><strong>' + $vacationTaskCount + '</strong> ' + (Esc $labels.caveatVacationMiddle) + ' <em>' + (Esc $labels.vacationProjectName) + '</em> &#8212; ' + (Esc $labels.caveatVacationSuffix) + '</li>')
[void]$L.Add('  </ul>')
[void]$L.Add('</div>')

# Month -> Project -> Employee accordion
foreach ($mk in $Months) {
    $mTotal = $teamMonthTotal[$mk]
    $projEntries = $monthProjects[$mk].GetEnumerator() | Sort-Object -Property @{Expression={$_.Value.hours}; Descending=$true}
    $mPortfolioHours = 0.0; foreach ($pe in $projEntries) { $mPortfolioHours += $pe.Value.hours }
    $mPct = if ($mTotal -gt 0) { [math]::Round($mPortfolioHours / $mTotal * 100, 1) } else { 0 }

    [void]$L.Add('<details class="month-block">')
    [void]$L.Add('  <summary>' + (MonthName $mk) + ' 2026<span class="sub">' + (Esc $labels.monthPortfolioLabel) + ': ' + (Fmt $mPortfolioHours) + ' &#1095; &mdash; ' + $mPct + '% ' + (Esc $labels.ofTeamTotalLabel) + ' (' + (Fmt $mTotal) + ' &#1095;)</span></summary>')
    [void]$L.Add('  <div class="month-body">')
    if (@($projEntries).Count -eq 0) {
        [void]$L.Add('    <div class="no-activity">' + (Esc $labels.noActivityLabel) + '</div>')
    }
    foreach ($pe in $projEntries) {
        $projName = $pe.Key
        $pHours   = $pe.Value.hours
        $pPct     = if ($mTotal -gt 0) { [math]::Round($pHours / $mTotal * 100, 1) } else { 0 }
        $barW     = if ($mPortfolioHours -gt 0) { [math]::Round($pHours / $mPortfolioHours * 100) } else { 0 }
        if ($barW -lt 3) { $barW = 3 }
        $warn = if ($cappedNames | Where-Object { $pe.Value.employees.ContainsKey($_) }) { ' <span class="warn-mark" title="' + (Esc $labels.warnTooltip) + '">&#9888;&#65039;</span>' } else { '' }

        [void]$L.Add('    <details class="project-block">')
        [void]$L.Add('      <summary><span class="proj-name">' + (Esc $projName) + $warn + '</span><span class="proj-metrics"><span class="proj-bar-wrap"><span class="proj-bar" style="display:block;width:' + $barW + '%;"></span></span><span class="proj-hours">' + (Fmt $pHours) + ' &#1095;</span><span class="proj-pct">' + $pPct + '%</span></span></summary>')
        [void]$L.Add('      <table class="emp-table">')
        [void]$L.Add('        <thead><tr><th>' + (Esc $labels.colEmployee) + '</th><th style="text-align:right;">' + (Esc $labels.colHours) + '</th><th style="text-align:right;">' + (Esc $labels.colPctPersonal) + '</th></tr></thead>')
        [void]$L.Add('        <tbody>')
        $empEntries = $pe.Value.employees.GetEnumerator() | Sort-Object -Property @{Expression={$_.Value}; Descending=$true}
        foreach ($ee in $empEntries) {
            $eName  = $ee.Key
            $eHours = $ee.Value
            $eTotal = $employeeMonthTotal["$eName|$mk"]
            $ePct   = if ($eTotal -gt 0) { [math]::Round($eHours / $eTotal * 100, 1) } else { $null }
            $eWarn  = if ($cappedNames -contains $eName) { ' <span class="warn-mark" title="' + (Esc $labels.warnTooltip) + '">&#9888;&#65039;</span>' } else { '' }
            $ePctDisp = if ($null -ne $ePct) { "$ePct%" } else { '&mdash;' }
            [void]$L.Add('          <tr><td>' + (Esc $eName) + $eWarn + '</td><td class="hours">' + (Fmt $eHours) + '</td><td class="pct">' + $ePctDisp + '</td></tr>')
        }
        [void]$L.Add('          <tr class="total-row"><td>' + (Esc $labels.totalProjectLabel) + '</td><td class="hours">' + (Fmt $pHours) + '</td><td></td></tr>')
        [void]$L.Add('        </tbody></table>')
        [void]$L.Add('    </details>')
    }
    [void]$L.Add('  </div>')
    [void]$L.Add('</details>')
}

# Footer
$genDate = Get-Date -Format 'dd.MM.yyyy HH:mm'
[void]$L.Add('<div style="text-align:center;color:#a0aec0;font-size:12px;padding:24px 0">' + (Esc $labels.generatedLabel) + ': ' + $genDate + ' &nbsp;|&nbsp; Asana time_tracking_entries &nbsp;|&nbsp; ' + $StartDisp + ' &#8212; ' + $EndDisp + '</div>')
[void]$L.Add('</div></body></html>')

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($htmlFile, $L, $utf8)
Write-Host "DONE: $htmlFile"
Write-Host "Team overall: $(Fmt $teamTotalPortfolio) / $(Fmt $teamTotalAll) h = $teamOverallPct% | employees with portfolio hours: $($portfolioEmployees.Count) | vacation entries: $vacationTaskCount"

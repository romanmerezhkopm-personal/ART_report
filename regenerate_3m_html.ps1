# Rebuilds 3m.html from the already-collected time_share_3m_data.json snapshot.
# No Asana API calls for task/time data (fast) - only 1 call to re-check live portfolio project count.
# Fixes the mojibake bug in generate_3m_time_share.ps1: PowerShell 5.1 read that .ps1 file's literal
# Cyrillic (month labels) using the system ANSI codepage instead of UTF-8, corrupting them. Task/project
# names fetched from the Asana API were NOT affected (JSON deserialization handles UTF-8 correctly) -
# only the 3 hardcoded Cyrillic literals in the script source were. Fix: use numeric HTML entities
# (ASCII-safe) for all Cyrillic text embedded directly in this script, consistent with the rest of the
# house style codebase (run_art_report.ps1 already does this everywhere else).

$ErrorActionPreference = "Stop"
$BASE = "D:\project\weekly_ART_report"
$htmlFile = "$BASE\3m.html"
$jsonFile = "$BASE\time_share_3m_data.json"

$Start  = "2026-05-01"
$End    = "2026-07-31"
$Months = @("2026-05","2026-06","2026-07")
$MonthLabel = [ordered]@{ "2026-05"="&#1052;&#1072;&#1081;"; "2026-06"="&#1048;&#1102;&#1085;&#1100;"; "2026-07"="&#1048;&#1102;&#1083;&#1100;" }
$LabelHtml  = "&#1052;&#1072;&#1081; - &#1048;&#1102;&#1083;&#1100; 2026"

$PAT     = (Get-Content "$BASE\asana_pat.txt" -Raw).Trim()
$headers = @{ Authorization = "Bearer $PAT" }
$apiBase = "https://app.asana.com/api/1.0"

# Live re-check of portfolio project count only (cheap, 1 call)
$PORTFOLIO_GID = "1213829329062998"
# Shared engine walks nested sub-portfolios (ART portfolio is nested since 07.10.2026). No try/catch
# with a hardcoded fallback count: a failed read must stop, not print a stale "13 projects" header.
. "D:\project\guardrails\asana_portfolio.ps1"
$portfolioProjCount = (Get-AsanaPortfolioProjects -PortfolioGid $PORTFOLIO_GID -RequestHeaders $headers).Count

$dataObj = Get-Content $jsonFile -Raw -Encoding UTF8 | ConvertFrom-Json
$teamMemberCount = @($dataObj.PSObject.Properties).Count

function Esc([string]$s) { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
function Fmt([double]$h) { if ($h -eq [math]::Floor($h)) { "$([int]$h)" } else { "$([math]::Round($h,2))" } }

# ------------------------------------------------------------
# Aggregate from JSON
# ------------------------------------------------------------
$teamMonth = [ordered]@{}
foreach ($mk in $Months) { $teamMonth[$mk] = @{ total = 0.0; portfolio = 0.0 } }
$teamTotalAll = 0.0; $teamTotalPortfolio = 0.0

$personSummary = @()
foreach ($prop in $dataObj.PSObject.Properties) {
    $name = $prop.Name
    $p = $prop.Value
    $sumTotal = 0.0; $sumPortfolio = 0.0
    $monthly = [ordered]@{}
    foreach ($mk in $Months) {
        $mm = $p.months.$mk
        $mt = [double]$mm.total / 60.0
        $mp = [double]$mm.portfolio / 60.0
        $monthly[$mk] = @{ total = $mt; portfolio = $mp; pct = if ($mt -gt 0) { [math]::Round($mp / $mt * 100, 1) } else { $null } }
        $sumTotal += $mt; $sumPortfolio += $mp
        $teamMonth[$mk].total += $mt; $teamMonth[$mk].portfolio += $mp
    }
    if ($sumTotal -le 0) { continue }
    $teamTotalAll += $sumTotal; $teamTotalPortfolio += $sumPortfolio
    $overallPct = [math]::Round($sumPortfolio / $sumTotal * 100, 1)
    $taskGids = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($tk in $p.tasks) { if ([bool]$tk.isPortfolio) { [void]$taskGids.Add([string]$tk.url) } }
    $personSummary += [ordered]@{
        name = $name; monthly = $monthly; totalAll = $sumTotal; totalPortfolio = $sumPortfolio
        pct = $overallPct; taskCount = $taskGids.Count; tasks = $p.tasks
    }
}
$sortedPersons = $personSummary | Sort-Object -Property @{Expression={$_.pct};Descending=$true}, @{Expression={$_.totalPortfolio};Descending=$true}
$inactiveNames = @($dataObj.PSObject.Properties.Name | Where-Object { $n = $_; -not ($personSummary | Where-Object { $_.name -eq $n }) } | Sort-Object)

$teamOverallPct = if ($teamTotalAll -gt 0) { [math]::Round($teamTotalPortfolio / $teamTotalAll * 100, 1) } else { 0 }
$activeCount = $personSummary.Count
$maxPct = ($sortedPersons | ForEach-Object { $_.pct } | Measure-Object -Maximum).Maximum
if (-not $maxPct -or $maxPct -le 0) { $maxPct = 100 }

$barColors = @('#667eea','#764ba2','#f093fb','#4facfe','#f5576c','#fd746c','#43e97b','#fa709a','#30cfd0','#feb692')

$StartDisp = ([datetime]::ParseExact($Start,'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')
$EndDisp   = ([datetime]::ParseExact($End,  'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')

# ------------------------------------------------------------
# Data-quality caveats (found by inspection of the first HTML build)
# ------------------------------------------------------------
$cappedNames = @('Ivan Monarkha','Roman Merezhko')  # hit exactly 100 tasks.search results -> Asana search API doesn't paginate past 100, totals may be undercounted
# Built from numeric char codes (not a literal) - PowerShell 5.1 misreads literal Cyrillic in .ps1
# source files under the system ANSI codepage (no BOM), which is exactly the bug this script fixes
# for the month labels. Matching by codepoint keeps this comparison immune to the same corruption.
$vacKeyword = ([char[]]@(0x41E,0x442,0x43F,0x443,0x441,0x43A,0x430)) -join ''  # "Отпуска"
function IsVacationProject([string]$proj) { return $proj -like "*$vacKeyword*" }
$vacationTaskCount = 0
foreach ($p in $sortedPersons) { foreach ($tk in $p.tasks) { if (IsVacationProject ([string]$tk.project)) { $vacationTaskCount++ } } }

$L = [System.Collections.Generic.List[string]]::new()
[void]$L.Add('<!DOCTYPE html>')
[void]$L.Add('<html lang="ru">')
[void]$L.Add('<head>')
[void]$L.Add('<meta charset="UTF-8">')
[void]$L.Add('<title>ART Portfolio &#8212; &#1044;&#1086;&#1083;&#1103; &#1074;&#1088;&#1077;&#1084;&#1077;&#1085;&#1080; &#1080;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1077;&#1081; (' + $LabelHtml + ')</title>')
[void]$L.Add('<style>')
[void]$L.Add('* { box-sizing:border-box; margin:0; padding:0; }')
[void]$L.Add('body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#f5f6fa; color:#2d3748; font-size:14px; }')
[void]$L.Add('.container { max-width:1200px; margin:0 auto; padding:24px; }')
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
[void]$L.Add('.section-title { font-size:16px; font-weight:700; color:#4a5568; margin-bottom:12px; display:flex; align-items:center; gap:8px; }')
[void]$L.Add('.section-title::before { content:""; display:block; width:4px; height:18px; background:#667eea; border-radius:2px; }')
[void]$L.Add('.section-title a { color:inherit; text-decoration:none; }')
[void]$L.Add('.section-title a:hover { text-decoration:underline; }')
[void]$L.Add('.card { background:white; border-radius:12px; padding:20px 24px; margin-bottom:24px; box-shadow:0 1px 3px rgba(0,0,0,.08); }')
[void]$L.Add('.summary-table { width:100%; border-collapse:collapse; }')
[void]$L.Add('.summary-table th { background:#f7f8fc; text-align:left; padding:10px 14px; font-weight:600; font-size:12px; color:#718096; text-transform:uppercase; letter-spacing:.5px; border-bottom:2px solid #e2e8f0; }')
[void]$L.Add('.summary-table td { padding:10px 14px; border-bottom:1px solid #f0f2f7; vertical-align:middle; }')
[void]$L.Add('.summary-table tr:hover td { background:#f7f8fc; }')
[void]$L.Add('.bar-wrap { width:100%; background:#edf2f7; border-radius:4px; height:8px; min-width:80px; }')
[void]$L.Add('.bar { height:8px; border-radius:4px; background:#667eea; }')
[void]$L.Add('.badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:11px; font-weight:600; }')
[void]$L.Add('.rank-1 { color:#744210; background:#fefcbf; } .rank-2 { color:#1a365d; background:#bee3f8; } .rank-3 { color:#22543d; background:#c6f6d5; }')
[void]$L.Add('.hours { font-weight:700; font-size:15px; color:#2d3748; }')
[void]$L.Add('.pct { font-weight:600; color:#718096; font-size:13px; }')
[void]$L.Add('.warn-mark { color:#d69e2e; font-weight:700; cursor:help; }')
[void]$L.Add('.dist-chart { display:flex; flex-direction:column; gap:10px; }')
[void]$L.Add('.dist-row { display:flex; align-items:center; gap:12px; }')
[void]$L.Add('.dist-label { width:220px; font-size:13px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; flex-shrink:0; }')
[void]$L.Add('.dist-bar-wrap { flex:1; background:#edf2f7; border-radius:4px; height:20px; }')
[void]$L.Add('.dist-bar { height:20px; border-radius:4px; display:flex; align-items:center; padding-left:8px; font-size:11px; color:white; font-weight:600; white-space:nowrap; min-width:36px; }')
[void]$L.Add('.dist-val { width:130px; text-align:right; font-size:12px; color:#718096; flex-shrink:0; }')
[void]$L.Add('.dept-grid { display:grid; grid-template-columns:repeat(3,1fr); gap:12px; }')
[void]$L.Add('.dept-card { background:#f7f8fc; border-radius:8px; padding:16px; text-align:center; border:1px solid #e2e8f0; }')
[void]$L.Add('.dept-card .dept-name { font-size:12px; font-weight:600; color:#718096; text-transform:uppercase; letter-spacing:.5px; margin-bottom:8px; }')
[void]$L.Add('.dept-card .dept-hours { font-size:24px; font-weight:700; color:#2d3748; }')
[void]$L.Add('.dept-card .dept-pct { font-size:12px; color:#a0aec0; margin-top:2px; }')
[void]$L.Add('details { margin-bottom:8px; }')
[void]$L.Add('details summary { cursor:pointer; padding:10px 14px; background:#f7f8fc; border-radius:8px; font-weight:600; font-size:13px; list-style:none; display:flex; align-items:center; justify-content:space-between; border:1px solid #e2e8f0; }')
[void]$L.Add('details summary::-webkit-details-marker { display:none; }')
[void]$L.Add('details summary::after { content:"\25B8"; color:#a0aec0; font-size:12px; }')
[void]$L.Add('details[open] summary::after { content:"\25BE"; }')
[void]$L.Add('details[open] summary { border-radius:8px 8px 0 0; }')
[void]$L.Add('.detail-content { border:1px solid #e2e8f0; border-top:none; border-radius:0 0 8px 8px; overflow:hidden; }')
[void]$L.Add('.detail-table { width:100%; border-collapse:collapse; }')
[void]$L.Add('.detail-table th { background:#f0f4f8; padding:8px 12px; text-align:left; font-size:11px; color:#718096; text-transform:uppercase; letter-spacing:.4px; }')
[void]$L.Add('.detail-table td { padding:8px 12px; border-bottom:1px solid #f0f2f7; font-size:13px; }')
[void]$L.Add('.detail-table tr:hover td { background:#f7f8fc; }')
[void]$L.Add('.task-link { color:#5a67d8; text-decoration:none; }')
[void]$L.Add('.task-link:hover { text-decoration:underline; }')
[void]$L.Add('.total-row td { font-weight:700; background:#f7f8fc; }')
[void]$L.Add('.pf-badge { display:inline-block; padding:1px 7px; border-radius:8px; font-size:10px; font-weight:600; }')
[void]$L.Add('.pf-yes { background:#c6f6d5; color:#276749; }')
[void]$L.Add('.pf-no { background:#edf2f7; color:#718096; }')
[void]$L.Add('.vac-row td { background:#fffbea; }')
[void]$L.Add('@media(max-width:900px){ .dept-grid{ grid-template-columns:repeat(1,1fr); } }')
[void]$L.Add('@media(max-width:600px){ .dist-label{ width:130px; } .dist-val{ width:100px; } }')
[void]$L.Add('</style>')
[void]$L.Add('</head>')
[void]$L.Add('<body><div class="container">')

# Header
[void]$L.Add('<div class="header">')
[void]$L.Add('  <h1>ART Portfolio &#8212; &#1044;&#1086;&#1083;&#1103; &#1074;&#1088;&#1077;&#1084;&#1077;&#1085;&#1080; &#1080;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1077;&#1081;</h1>')
[void]$L.Add('  <div class="meta">&#1055;&#1077;&#1088;&#1080;&#1086;&#1076;: ' + $StartDisp + ' &#8212; ' + $EndDisp + ' &nbsp;|&nbsp; &#1055;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1100;: ART Portfolio (' + $portfolioProjCount + ' &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1086;&#1074;) &nbsp;|&nbsp; &#1050;&#1086;&#1084;&#1072;&#1085;&#1076;&#1072;: Art Team &nbsp;|&nbsp; &#1048;&#1089;&#1090;&#1086;&#1095;&#1085;&#1080;&#1082;: Asana time_tracking_entries</div>')
[void]$L.Add('  <div class="stats">')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + (Fmt $teamTotalPortfolio) + '</div><div class="stat-lbl">&#1063;&#1072;&#1089;&#1086;&#1074; &#1085;&#1072; &#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1100;</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + (Fmt $teamTotalAll) + '</div><div class="stat-lbl">&#1063;&#1072;&#1089;&#1086;&#1074; &#1074;&#1089;&#1077;&#1075;&#1086; (Art Team)</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $teamOverallPct + '%</div><div class="stat-lbl">&#1044;&#1086;&#1083;&#1103; &#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1103;</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $activeCount + '</div><div class="stat-lbl">&#1048;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1077;&#1081; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</div></div>')
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Notice (green - method)
[void]$L.Add('<div class="notice-g">&#9989; <strong>&#1044;&#1072;&#1085;&#1085;&#1099;&#1077; &#1086;&#1090;&#1092;&#1080;&#1083;&#1100;&#1090;&#1088;&#1086;&#1074;&#1072;&#1085;&#1099; &#1095;&#1077;&#1088;&#1077;&#1079; Asana time_tracking_entries API (&#1092;&#1080;&#1083;&#1100;&#1090;&#1088; &#1087;&#1086; <em>entered_on</em>).</strong> &#1055;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1100; &#8212; &#1079;&#1072;&#1076;&#1072;&#1095;&#1080; &#1080;&#1079; ART Portfolio (&#1078;&#1080;&#1074;&#1086;&#1081; &#1089;&#1087;&#1080;&#1089;&#1086;&#1082; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1086;&#1074;). &#1048;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1080; &#8212; &#1091;&#1095;&#1072;&#1089;&#1090;&#1085;&#1080;&#1082;&#1080; &#1082;&#1086;&#1084;&#1072;&#1085;&#1076;&#1099; Art Team. &laquo;&#1044;&#1086;&#1083;&#1103; &#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1103;&raquo; = Actual Time &#1085;&#1072; &#1079;&#1072;&#1076;&#1072;&#1095;&#1072;&#1093; ART Portfolio &#247; Actual Time &#1085;&#1072; &#1042;&#1057;&#1045;&#1061; &#1079;&#1072;&#1076;&#1072;&#1095;&#1072;&#1093; &#1080;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1103; (&#1083;&#1102;&#1073;&#1099;&#1077; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1099;) &#1079;&#1072; &#1090;&#1086;&#1090; &#1078;&#1077; &#1084;&#1077;&#1089;&#1103;&#1094;. &#1057;&#1091;&#1084;&#1084;&#1072; &#1079;&#1072; 3 &#1084;&#1077;&#1089;&#1103;&#1094;&#1072; &#8212; &#1090;&#1072;&#1082; &#1078;&#1077; &#1089;&#1086;&#1086;&#1090;&#1085;&#1086;&#1096;&#1077;&#1085;&#1080;&#1077;, &#1085;&#1086; &#1087;&#1086; &#1089;&#1091;&#1084;&#1084;&#1072;&#1084; &#1074;&#1089;&#1077;&#1093; &#1090;&#1088;&#1105;&#1093; &#1084;&#1077;&#1089;&#1103;&#1094;&#1077;&#1074;.</div>')

# Notice (yellow - caveats)
[void]$L.Add('<div class="notice-y">&#9888;&#65039; <strong>&#1044;&#1074;&#1072; &#1086;&#1075;&#1088;&#1072;&#1085;&#1080;&#1095;&#1077;&#1085;&#1080;&#1103; &#1084;&#1077;&#1090;&#1086;&#1076;&#1080;&#1082;&#1080;:</strong>')
[void]$L.Add('  <ul>')
[void]$L.Add('    <li><strong>Ivan Monarkha, Roman Merezhko</strong> &#8212; &#1091; &#1101;&#1090;&#1080;&#1093; &#1076;&#1074;&#1091;&#1093; &#1088;&#1086;&#1074;&#1085;&#1086; 100 &#1079;&#1072;&#1076;&#1072;&#1095;-&#1082;&#1072;&#1085;&#1076;&#1080;&#1076;&#1072;&#1090;&#1086;&#1074; &#8212; Asana Search API &#1085;&#1077; &#1087;&#1072;&#1075;&#1080;&#1085;&#1080;&#1088;&#1091;&#1077;&#1090;&#1089;&#1103; &#1076;&#1072;&#1083;&#1100;&#1096;&#1077; 100 &#1088;&#1077;&#1079;&#1091;&#1083;&#1100;&#1090;&#1072;&#1090;&#1086;&#1074;, &#1090;&#1072;&#1082; &#1095;&#1090;&#1086; &#1080;&#1093; &laquo;&#1063;&#1072;&#1089;&#1086;&#1074; &#1074;&#1089;&#1077;&#1075;&#1086;&raquo; &#1080; % &#1084;&#1086;&#1075;&#1091;&#1090; &#1073;&#1099;&#1090;&#1100; &#1079;&#1072;&#1085;&#1080;&#1078;&#1077;&#1085;&#1099; &#8212; &#1087;&#1086;&#1084;&#1077;&#1095;&#1077;&#1085;&#1099; &&#8203; &#1074; &#1090;&#1072;&#1073;&#1083;&#1080;&#1094;&#1072;&#1093; &#1079;&#1085;&#1072;&#1082;&#1086;&#1084; &#8264;&#8264;.</li>')
[void]$L.Add('    <li><strong>' + $vacationTaskCount + ' &#1079;&#1072;&#1087;&#1080;&#1089;&#1077;&#1081;</strong> &#1074;&#1088;&#1077;&#1084;&#1077;&#1085;&#1080; &#1091;&#1095;&#1090;&#1077;&#1085;&#1099; &#1074; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1077; <em>CAS.AI - &#1054;&#1090;&#1087;&#1091;&#1089;&#1082;&#1072;, &#1073;&#1086;&#1083;&#1100;&#1085;&#1080;&#1095;&#1085;&#1099;&#1077;</em> &#8212; &#1101;&#1090;&#1086; &#1074;&#1093;&#1086;&#1076;&#1080;&#1090; &#1074; &laquo;&#1086;&#1073;&#1097;&#1077;&#1077; &#1074;&#1088;&#1077;&#1084;&#1103;&raquo; (&#1079;&#1085;&#1072;&#1084;&#1077;&#1085;&#1072;&#1090;&#1077;&#1083;&#1100; %), &#1090;&#1072;&#1082; &#1095;&#1090;&#1086; &#1091; &#1090;&#1077;&#1093;, &#1082;&#1090;&#1086; &#1073;&#1099;&#1083; &#1074; &#1086;&#1090;&#1087;&#1091;&#1089;&#1082;&#1077;/&#1085;&#1072; &#1073;&#1086;&#1083;&#1100;&#1085;&#1080;&#1095;&#1085;&#1086;&#1084;, &#1076;&#1086;&#1083;&#1103; &#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1103; &#1079;&#1072;&#1085;&#1080;&#1078;&#1077;&#1085;&#1072; &#1080;&#1089;&#1082;&#1091;&#1089;&#1089;&#1090;&#1074;&#1077;&#1085;&#1085;&#1086; (&#1086;&#1090;&#1087;&#1091;&#1089;&#1082;/&#1073;&#1086;&#1083;&#1100;&#1085;&#1080;&#1095;&#1085;&#1099;&#1081; &#8801; &#1085;&#1077; &#1088;&#1072;&#1073;&#1086;&#1090;&#1072;, &#1085;&#1086; &#1089;&#1095;&#1080;&#1090;&#1072;&#1077;&#1090;&#1089;&#1103; &#1074; &#1079;&#1085;&#1072;&#1084;&#1077;&#1085;&#1072;&#1090;&#1077;&#1083;&#1077;).</li>')
[void]$L.Add('  </ul>')
[void]$L.Add('</div>')

# Month grid
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title" id="months"><a href="#months">&#1044;&#1086;&#1083;&#1103; &#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1103; &#1087;&#1086; &#1084;&#1077;&#1089;&#1103;&#1094;&#1072;&#1084; (&#1074;&#1089;&#1103; &#1082;&#1086;&#1084;&#1072;&#1085;&#1076;&#1072;)</a></div>')
[void]$L.Add('  <div class="dept-grid">')
foreach ($mk in $Months) {
    $mt = $teamMonth[$mk].total; $mp = $teamMonth[$mk].portfolio
    $mpct = if ($mt -gt 0) { [math]::Round($mp / $mt * 100, 1) } else { 0 }
    [void]$L.Add('    <div class="dept-card"><div class="dept-name">' + $MonthLabel[$mk] + ' 2026</div><div class="dept-hours">' + $mpct + '%</div><div class="dept-pct">' + (Fmt $mp) + ' &#1080;&#1079; ' + (Fmt $mt) + ' &#1095;</div></div>')
}
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Distribution chart
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title" id="distribution"><a href="#distribution">&#1044;&#1086;&#1083;&#1103; &#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1103; &#1087;&#1086; &#1080;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1103;&#1084; (&#1079;&#1072; 3 &#1084;&#1077;&#1089;&#1103;&#1094;&#1072;)</a></div>')
[void]$L.Add('  <div class="dist-chart">')
$ci = 0
foreach ($p in $sortedPersons) {
    $barW = [math]::Round($p.pct / $maxPct * 100)
    if ($barW -lt 3) { $barW = 3 }
    $col = $barColors[$ci % $barColors.Count]
    $warn = if ($cappedNames -contains $p.name) { ' <span class="warn-mark" title="Search API cap: &#1074;&#1086;&#1079;&#1084;&#1086;&#1078;&#1085;&#1099; &#1085;&#1077;&#1076;&#1086;&#1089;&#1095;&#1080;&#1090;&#1072;&#1085;&#1085;&#1099;&#1077; &#1079;&#1072;&#1076;&#1072;&#1095;&#1080;">&#9888;&#65039;</span>' } else { '' }
    [void]$L.Add('    <div class="dist-row"><div class="dist-label">' + (Esc $p.name) + $warn + '</div><div class="dist-bar-wrap"><div class="dist-bar" style="width:' + $barW + '%;background:' + $col + ';">' + $p.pct + '%</div></div><div class="dist-val">' + (Fmt $p.totalPortfolio) + ' &#1080;&#1079; ' + (Fmt $p.totalAll) + ' &#1095;</div></div>')
    $ci++
}
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Summary table
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title" id="summary"><a href="#summary">&#1057;&#1074;&#1086;&#1076;&#1085;&#1072;&#1103; &#1090;&#1072;&#1073;&#1083;&#1080;&#1094;&#1072; &#1087;&#1086; &#1080;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1103;&#1084;</a></div>')
[void]$L.Add('  <table class="summary-table">')
[void]$L.Add('    <thead><tr><th>#</th><th>&#1048;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1100;</th><th>' + $MonthLabel['2026-05'] + '</th><th>' + $MonthLabel['2026-06'] + '</th><th>' + $MonthLabel['2026-07'] + '</th><th>&#1047;&#1072;&#1076;&#1072;&#1095;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074; (&#1087;&#1086;&#1088;&#1090;&#1092;/&#1074;&#1089;&#1077;&#1075;&#1086;)</th><th>%</th><th>&#1044;&#1086;&#1083;&#1103;</th></tr></thead>')
[void]$L.Add('    <tbody>')
$ri = 0
foreach ($p in $sortedPersons) {
    $ri++
    $rankBadge = switch ($ri) {
        1 { '<span class="badge rank-1">1</span>' }
        2 { '<span class="badge rank-2">2</span>' }
        3 { '<span class="badge rank-3">3</span>' }
        default { "$ri" }
    }
    $monthCells = ""
    foreach ($mk in $Months) {
        $mm = $p.monthly[$mk]
        $cell = if ($null -ne $mm.pct) { "$($mm.pct)%<br><small style='color:#a0aec0'>$(Fmt $mm.portfolio) / $(Fmt $mm.total) &#1095;</small>" } else { '<span style="color:#cbd5e0">&mdash;</span>' }
        $monthCells += '<td style="text-align:center;font-size:12px;">' + $cell + '</td>'
    }
    $barW = [math]::Round($p.pct / $maxPct * 100)
    $warn = if ($cappedNames -contains $p.name) { ' <span class="warn-mark" title="&#1076;&#1072;&#1085;&#1085;&#1099;&#1077; &#1084;&#1086;&#1075;&#1091;&#1090; &#1073;&#1099;&#1090;&#1100; &#1085;&#1077;&#1087;&#1086;&#1083;&#1085;&#1099;&#1084;&#1080; (&gt;100 &#1079;&#1072;&#1076;&#1072;&#1095;)">&#9888;&#65039;</span>' } else { '' }
    [void]$L.Add('      <tr><td>' + $rankBadge + '</td><td><strong>' + (Esc $p.name) + '</strong>' + $warn + '</td>' + $monthCells + '<td style="text-align:center;">' + $p.taskCount + '</td><td class="hours">' + (Fmt $p.totalPortfolio) + ' / ' + (Fmt $p.totalAll) + '</td><td class="pct">' + $p.pct + '%</td><td><div class="bar-wrap"><div class="bar" style="width:' + $barW + '%"></div></div></td></tr>')
}
[void]$L.Add('    </tbody></table>')
[void]$L.Add('</div>')

# Details per person
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title" id="details"><a href="#details">&#1044;&#1077;&#1090;&#1072;&#1083;&#1080;&#1079;&#1072;&#1094;&#1080;&#1103; &#1087;&#1086; &#1079;&#1072;&#1076;&#1072;&#1095;&#1072;&#1084; &#1080;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1077;&#1081;</a></div>')
foreach ($p in $sortedPersons) {
    $warn = if ($cappedNames -contains $p.name) { ' <span class="warn-mark" title="&#1076;&#1072;&#1085;&#1085;&#1099;&#1077; &#1084;&#1086;&#1075;&#1091;&#1090; &#1073;&#1099;&#1090;&#1100; &#1085;&#1077;&#1087;&#1086;&#1083;&#1085;&#1099;&#1084;&#1080;">&#9888;&#65039;</span>' } else { '' }
    [void]$L.Add('  <details>')
    [void]$L.Add('    <summary>' + (Esc $p.name) + $warn + '&nbsp;&nbsp;<span style="color:#718096;font-weight:400">' + $p.pct + '% &mdash; ' + (Fmt $p.totalPortfolio) + ' &#1080;&#1079; ' + (Fmt $p.totalAll) + ' &#1095;</span></summary>')
    [void]$L.Add('    <div class="detail-content"><table class="detail-table">')
    [void]$L.Add('      <thead><tr><th>&#1047;&#1072;&#1076;&#1072;&#1095;&#1072;</th><th>&#1052;&#1077;&#1089;&#1103;&#1094;</th><th>&#1055;&#1088;&#1086;&#1077;&#1082;&#1090;</th><th>&#1055;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1100;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th></tr></thead>')
    [void]$L.Add('      <tbody>')
    foreach ($tk in ($p.tasks | Sort-Object { $_.month }, { -$_.hours })) {
        $pf = if ([bool]$tk.isPortfolio) { '<span class="pf-badge pf-yes">&#1044;&#1072;</span>' } else { '<span class="pf-badge pf-no">&#1053;&#1077;&#1090;</span>' }
        $isVac = IsVacationProject ([string]$tk.project)
        $trCls = if ($isVac) { ' class="vac-row"' } else { '' }
        [void]$L.Add('        <tr' + $trCls + '><td><a class="task-link" href="' + $tk.url + '" target="_blank">' + (Esc $tk.name) + '</a></td><td>' + $MonthLabel[[string]$tk.month] + '</td><td>' + (Esc $tk.project) + '</td><td>' + $pf + '</td><td class="hours">' + (Fmt $tk.hours) + '</td></tr>')
    }
    [void]$L.Add('        <tr class="total-row"><td colspan="4">&#1048;&#1058;&#1054;&#1043;&#1054; (&#1074;&#1089;&#1077;&#1075;&#1086; &#1079;&#1072; 3 &#1084;&#1077;&#1089;&#1103;&#1094;&#1072;)</td><td>' + (Fmt $p.totalAll) + '</td></tr>')
    [void]$L.Add('      </tbody></table></div>')
    [void]$L.Add('  </details>')
}
if ($inactiveNames.Count -gt 0) {
    [void]$L.Add('  <div style="margin-top:14px;font-size:12px;color:#718096;">&#1041;&#1077;&#1079; Actual Time &#1079;&#1072; &#1074;&#1077;&#1089;&#1100; &#1087;&#1077;&#1088;&#1080;&#1086;&#1076; (&#1085;&#1080; &#1087;&#1086; &#1086;&#1076;&#1085;&#1086;&#1081; &#1079;&#1072;&#1076;&#1072;&#1095;&#1077;):</div>')
    [void]$L.Add('  <div style="display:flex;flex-wrap:wrap;gap:4px;margin-top:6px;">')
    foreach ($nm in $inactiveNames) { [void]$L.Add('    <span style="background:#edf2f7;color:#718096;padding:2px 10px;border-radius:10px;font-size:12px;">' + (Esc $nm) + '</span>') }
    [void]$L.Add('  </div>')
}
[void]$L.Add('</div>')

# Footer
$genDate = Get-Date -Format 'dd.MM.yyyy HH:mm'
[void]$L.Add('<div style="text-align:center;color:#a0aec0;font-size:12px;padding:24px 0">&#1057;&#1075;&#1077;&#1085;&#1077;&#1088;&#1080;&#1088;&#1086;&#1074;&#1072;&#1085;&#1086;: ' + $genDate + ' &nbsp;|&nbsp; Asana time_tracking_entries &nbsp;|&nbsp; ' + $StartDisp + ' &#8212; ' + $EndDisp + '</div>')
[void]$L.Add('</div></body></html>')

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($htmlFile, $L, $utf8)
Write-Host "DONE: $htmlFile"
Write-Host "Team: $activeCount active / $teamMemberCount total, overall portfolio share: $teamOverallPct%"

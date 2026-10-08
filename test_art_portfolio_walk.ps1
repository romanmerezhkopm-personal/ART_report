# Thin test for the shared engine D:\project\guardrails\asana_portfolio.ps1, with this repo's parameters.
# Offline cases (fake API) prove the rules; the live case proves the real ART portfolio is fully seen.
# Run:  powershell -File test_art_portfolio_walk.ps1          (offline + live)
#       powershell -File test_art_portfolio_walk.ps1 -OfflineOnly
param([switch]$OfflineOnly)
$ErrorActionPreference = "Stop"
. "D:\project\guardrails\asana_portfolio.ps1"

$ART_PORTFOLIO_GID = "1213829329062998"
# GIDs that MUST be found in the live ART portfolio: 8 root projects + 10 inside the 3 sub-portfolios
# (08.10.2026). A project that stops being found = a flat/partial read has come back.
$REQUIRED_LIVE = @(
    "1219014698904107","1217850380511462","1218619312758854","1213910439454138","1213910439713691",
    "1213911620513682","1213911895502718","1213911862802481",                       # root
    "1213993120177405","1213598068805302",                                          # CAS.Marketing_ART
    "1216704431904924","1216704431904918","1216704431904914","1213879913329451",    # CAS.AI_ART
    "1213598068805254","1213598068805258","1213599181255292","1213599181255288"     # CAS.Games_ART
)

$fail = 0
function Check([string]$name, [bool]$ok) { if ($ok) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name"; $script:fail++ } }
function Item($type, $gid, $name, $arch = $false) { [pscustomobject]@{ resource_type = $type; gid = $gid; name = $name; archived = $arch } }
# fake API: tree = hashtable portfolioGid -> @{ items = @(...); next = <offset or $null> }
function Fake($tree) { $t = $tree; { param($url)
    if ($url -notmatch 'portfolios/(\w+)/items') { throw "bad url $url" }
    $g = $Matches[1]; if (-not $t.ContainsKey($g)) { throw "fetch failed for $g" }
    $o = if ($url -match 'offset=(\w+)') { $Matches[1] } else { "0" }
    $page = $t[$g][$o]; [pscustomobject]@{ data = $page.items; next_page = $(if ($page.next) { [pscustomobject]@{ offset = $page.next } } else { $null }) } }.GetNewClosure() }
function Throws([scriptblock]$b) { try { & $b; $false } catch { $true } }

# --- must PASS --------------------------------------------------------------
$r = Get-AsanaPortfolioProjects -PortfolioGid "R" -Fetcher (Fake @{ R = @{ "0" = @{ items = @((Item project p1 A), (Item portfolio S sub), (Item project p2 B)) } }
                                                                      S = @{ "0" = @{ items = @((Item project p3 C)) } } })
Check "nested: project inside a sub-portfolio is found (the 08.10.2026 bug)" (($r.Keys -join ',') -eq 'p1,p3,p2')
$r = Get-AsanaPortfolioProjects -PortfolioGid "R" -Fetcher (Fake @{ R = @{ "0" = @{ items = @((Item project p1 A), (Item project p2 B $true)) } } })
Check "archived project is skipped" (($r.Keys -join ',') -eq 'p1')
$r = Get-AsanaPortfolioProjects -PortfolioGid "R" -Fetcher (Fake @{ R = @{ "0" = @{ items = @((Item portfolio S s), (Item project p1 A)) } }
                                                                      S = @{ "0" = @{ items = @((Item portfolio R back), (Item project p2 B)) } } })
Check "cycle R -> S -> R terminates, no duplicates" (($r.Keys -join ',') -eq 'p2,p1')
$r = Get-AsanaPortfolioProjects -PortfolioGid "R" -Fetcher (Fake @{ R = @{ "0" = @{ items = @((Item project p1 A)); next = "1" }; "1" = @{ items = @((Item project p2 B)) } } })
Check "pagination: second page is read" (($r.Keys -join ',') -eq 'p1,p2')

# --- must BLOCK -------------------------------------------------------------
Check "unknown resource_type throws (not skipped)" (Throws { Get-AsanaPortfolioProjects -PortfolioGid "R" -Fetcher (Fake @{ R = @{ "0" = @{ items = @((Item project p1 A), (Item goal g1 G)) } } }) })
Check "failed fetch of a nested portfolio throws (no partial list)" (Throws { Get-AsanaPortfolioProjects -PortfolioGid "R" -Fetcher (Fake @{ R = @{ "0" = @{ items = @((Item portfolio MISSING m), (Item project p1 A)) } } }) })

# --- auth regression (08.10.2026): a caller-supplied Fetcher that reads the CALLER's $headers --------
# The engine must not shadow it (variable names are case-insensitive; a param named $Headers did).
$headers = @{ ok = "token" }
$authFetcher = { param($url)
    if ($headers.ok -ne "token") { throw "Not Authorized (engine shadowed caller's `$headers)" }
    [pscustomobject]@{ data = @([pscustomobject]@{ resource_type = "project"; gid = "p1"; name = "A"; archived = $false }); next_page = $null } }
$r = Get-AsanaPortfolioProjects -PortfolioGid "R" -Fetcher $authFetcher
Check "caller's `$headers is visible to a custom Fetcher (no shadowing)" (($r.Keys -join ',') -eq 'p1')
Remove-Variable headers

# --- live: the real ART portfolio -------------------------------------------
if (-not $OfflineOnly) {
    $pat = (Get-Content "D:\project\weekly_ART_report\asana_pat.txt" -Raw).Trim()
    $live = Get-AsanaPortfolioProjects -PortfolioGid $ART_PORTFOLIO_GID -RequestHeaders @{ Authorization = "Bearer $pat" }
    $missing = @($REQUIRED_LIVE | Where-Object { -not $live.Contains($_) })
    Check "live ART portfolio: all $($REQUIRED_LIVE.Count) required projects found ($($live.Count) total)" ($missing.Count -eq 0)
    if ($missing.Count) { Write-Host "      missing: $($missing -join ', ')" }
}
if ($fail) { Write-Host "`n$fail check(s) FAILED"; exit 1 } else { Write-Host "`nAll checks passed"; exit 0 }

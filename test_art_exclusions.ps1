# Thin test for art_exclusions.ps1 - who the ART report leaves out. Names are real (2026-10 run):
# Ivan Symkanych / Yurii Polukhin = GameDev members with Motion Design hours, Illia Natalukha / Anton Tuz =
# Motion Design artists outside GameDev.
# Run:  powershell -File test_art_exclusions.ps1            (offline + live)
#       powershell -File test_art_exclusions.ps1 -OfflineOnly
param([switch]$OfflineOnly)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\art_exclusions.ps1"

$fail = 0
function Check([string]$name, [bool]$ok) { if ($ok) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name"; $script:fail++ } }
function Throws([scriptblock]$b) { try { & $b; $false } catch { $true } }

$r = Resolve-ArtExcludedAssignees @('Roman Merezhko') @('Ivan Symkanych', 'Yurii Polukhin') @('Anton Tuz', 'Illia Natalukha')
# --- must EXCLUDE -----------------------------------------------------------
Check "GameDev member is excluded" (($r.Excluded -contains 'Ivan Symkanych') -and ($r.Excluded -contains 'Yurii Polukhin'))
Check "Roman stays excluded" ($r.Excluded -contains 'Roman Merezhko')
# --- must KEEP --------------------------------------------------------------
Check "Motion Design artist outside GameDev stays in" ($r.Excluded -notcontains 'Illia Natalukha')
Check "Unassigned stays in (its hours belong to project totals)" ($r.Excluded -notcontains 'Unassigned')
$r = Resolve-ArtExcludedAssignees @('Roman Merezhko') @('Ivan Symkanych', 'Anton Tuz') @('Anton Tuz')
Check "person in BOTH teams stays in and is reported as a conflict" (($r.Excluded -notcontains 'Anton Tuz') -and ($r.Conflicts -contains 'Anton Tuz'))
# --- must BLOCK -------------------------------------------------------------
Check "empty GameDev team throws (no silent report with developers)" (Throws { Resolve-ArtExcludedAssignees @('Roman Merezhko') @() @('Anton Tuz') })
Check "Maryna Riabokon is in the base exclusion list" ($ART_BASE_EXCLUDED -contains 'Maryna Riabokon')

# --- hours go to whoever LOGGED them (Get-ArtPersonHours) -------------------------------------------
# Real October 2026 tasks: Maryna / Pavlo Gorpenko = assignees of CPP requests, the 8 h were logged by
# artists Katerina Grimailo / Artem Surin.
$ex = @('Roman Merezhko', 'Maryna Riabokon', 'Ivan Symkanych')
function Same($a, [hashtable]$b) { ($a.Count -eq $b.Count) -and -not ($b.Keys | Where-Object { [math]::Abs([double]$a[$_] - $b[$_]) -gt 0.001 }) }
# must COUNT for the logger
Check "assignee Maryna, logged by Katerina -> 8 h to Katerina" (Same (Get-ArtPersonHours @{ assignee = 'Maryna Riabokon'; hours = 8; by_logger = @{ 'Katerina Grimailo' = 480 } } $ex) @{ 'Katerina Grimailo' = 8 })
Check "assignee Pavlo (not excluded), logged by Artem -> 8 h to Artem, none to Pavlo" (Same (Get-ArtPersonHours @{ assignee = 'Pavlo Gorpenko'; hours = 8; by_logger = @{ 'Artem Surin' = 480 } } $ex) @{ 'Artem Surin' = 8 })
Check "same task read back from time_data JSON (PSCustomObject)" (Same (Get-ArtPersonHours ('{"assignee":"Maryna Riabokon","hours":8,"by_logger":{"Katerina Grimailo":480}}' | ConvertFrom-Json) $ex) @{ 'Katerina Grimailo' = 8 })
Check "old record without by_logger falls back to the assignee" (Same (Get-ArtPersonHours ('{"assignee":"Anton Tuz","hours":160}' | ConvertFrom-Json) $ex) @{ 'Anton Tuz' = 160 })
# must DROP excluded loggers
Check "Maryna's own entries dropped, the artist's kept" (Same (Get-ArtPersonHours @{ assignee = 'Maryna Riabokon'; hours = 9; by_logger = @{ 'Maryna Riabokon' = 60; 'Katerina Grimailo' = 480 } } $ex) @{ 'Katerina Grimailo' = 8 })
Check "developer's own entries dropped (task counts for nobody)" ((Get-ArtPersonHours @{ assignee = 'Ivan Symkanych'; hours = 20; by_logger = @{ 'Ivan Symkanych' = 1200 } } $ex).Count -eq 0)
Check "old record of an excluded assignee counts for nobody" ((Get-ArtPersonHours ('{"assignee":"Roman Merezhko","hours":5}' | ConvertFrom-Json) $ex).Count -eq 0)
Check "status-based record (by_logger {} , 0 h) counts for nobody, no assignee fallback" ((Get-ArtPersonHours ('{"assignee":"Anton Tuz","hours":0,"by_logger":{}}' | ConvertFrom-Json) $ex).Count -eq 0)

# --- live: the real teams ---------------------------------------------------
if (-not $OfflineOnly) {
    $h = @{ Authorization = "Bearer " + (Get-Content "$PSScriptRoot\asana_pat.txt" -Raw).Trim() }
    $dev = Get-AsanaTeamMemberNames $GAMEDEV_TEAM_GID $h
    $r = Resolve-ArtExcludedAssignees $ART_BASE_EXCLUDED $dev (Get-AsanaTeamMemberNames $ART_TEAM_GID $h)
    Check "live: GameDev - ALL Team read, $($dev.Count) members, $($r.Developers.Count) excluded" ($r.Developers.Count -gt 0)
    if ($r.Conflicts.Count) { Write-Host "      in both teams (kept in report): $($r.Conflicts -join ', ')" }
}
if ($fail) { Write-Host "`n$fail check(s) FAILED"; exit 1 } else { Write-Host "`nAll checks passed"; exit 0 }

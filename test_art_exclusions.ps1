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
Check "Denys Drahanov is in the base exclusion list" ($ART_BASE_EXCLUDED -contains 'Denys Drahanov')

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

# --- Find-ArtOutsideLoggers: a non-artist brought in by the logger rule ----------------------------
# Real October 2026: Drahanov logged 3 h on Oleksandr Smyslovskyi's Motion Design task, none on his own.
# Polina Dimitrova (Motion Design, outside Art Team) logged 152 h on her own tasks + 16 h on Oksana's.
$art = @('Katerina Grimailo', 'Oleksandr Smyslovskyi')
$exNoDrahanov = @('Roman Merezhko', 'Maryna Riabokon')
# Records as in time_data_2026-10.json (task 1219252452211800 for Drahanov); the Roman one is constructed:
# an excluded person on someone else's task.
$oct = @(
    @{ assignee = 'Oleksandr Smyslovskyi'; by_logger = @{ 'Denys Drahanov' = 180 } },
    @{ assignee = 'Polina Dimitrova';      by_logger = @{ 'Polina Dimitrova' = 9120 } },
    @{ assignee = 'Oksana Tsvyntarna';     by_logger = @{ 'Polina Dimitrova' = 960 } },
    @{ assignee = 'Maryna Riabokon';       by_logger = @{ 'Katerina Grimailo' = 480 } },
    @{ assignee = 'Oksana Tsvyntarna';     by_logger = @{ 'Roman Merezhko' = 60 } },
    @{ assignee = 'Alisa Nadvorna'; external = $true; by_logger = @{ 'Alisa Nadvorna' = 480 } }
)
$found = @(Find-ArtOutsideLoggers $oct $art $exNoDrahanov)
# must FLAG
Check "outsider with hours only on others' tasks is flagged (Drahanov 3 h)" (($found.Count -eq 1) -and ($found[0].Name -eq 'Denys Drahanov') -and ($found[0].Hours -eq 3))
# must PASS
Check "outsider who also logs on own tasks is not flagged (Polina)" (@($found | Where-Object { $_.Name -eq 'Polina Dimitrova' }).Count -eq 0)
Check "Art Team member logging on someone else's task is not flagged (Katerina)" (@($found | Where-Object { $_.Name -eq 'Katerina Grimailo' }).Count -eq 0)
Check "excluded people and external tasks are not flagged (Roman, Alisa ext)" (@($found | Where-Object { 'Roman Merezhko', 'Alisa Nadvorna' -contains $_.Name }).Count -eq 0)
Check "an outsider's EXTERNAL entries alone do not flag them" (@(Find-ArtOutsideLoggers @(@{ assignee = 'Oksana Tsvyntarna'; external = $true; by_logger = @{ 'Denys Drahanov' = 180 } }) $art $exNoDrahanov).Count -eq 0)
Check "once excluded, Drahanov is no longer flagged" (@(Find-ArtOutsideLoggers $oct $art $ART_BASE_EXCLUDED).Count -eq 0)

# --- Remove-ZeroHourProjects: a project with only 0 h status rows is left out -------------------------
# Real October 2026 rows (time_data_2026-10.json): Obby All Games = 12 ART Ready rows, 0 h; Build Car =
# 27 tracked tasks + 11 ART Ready rows; Anna Hrabko's external task attributed to "No project".
function New-Rows { @{
    'obby1' = @{ attributed_project = 'Obby All Games'; hours = 0.0; is_status_based = $true; assignee = 'Valentina Romashchenko'; external = $false }
    'obby2' = @{ attributed_project = 'Obby All Games'; hours = 0.0; is_status_based = $true; assignee = 'Vadym Flinta'; external = $false }
    'bc1'   = @{ attributed_project = 'Build Car'; hours = 3.0; is_status_based = $false; assignee = 'Igor Kuznetsov'; external = $false }
    'bc2'   = @{ attributed_project = 'Build Car'; hours = 0.0; is_status_based = $true;  assignee = 'Anna Hrabko'; external = $false }
    'ext1'  = @{ attributed_project = 'Obby All Games'; hours = 4.0; is_status_based = $false; assignee = 'Anna Hrabko'; external = $true }
    'ext2'  = @{ attributed_project = 'No project'; hours = 4.0; is_status_based = $false; assignee = 'Anna Hrabko'; external = $true }
} }
$rows = New-Rows
$gone = @(Remove-ZeroHourProjects $rows { param($t) $t.attributed_project })
# must LEAVE OUT
Check "project with only 0 h status rows is left out (Obby All Games)" (($gone -join ',') -eq 'Obby All Games' -and -not $rows.ContainsKey('obby1') -and -not $rows.ContainsKey('obby2'))
# must KEEP
Check "project with hours keeps its tracked task AND its ART Ready row (Build Car)" ($rows.ContainsKey('bc1') -and $rows.ContainsKey('bc2'))
Check "external tasks untouched, even with a 0 h project's name; they do not rescue it" ($rows.ContainsKey('ext1') -and $rows.ContainsKey('ext2'))
$rows = New-Rows; $rows.Remove('obby1'); $rows.Remove('obby2')
Check "nothing to leave out -> nothing removed" ((@(Remove-ZeroHourProjects $rows { param($t) $t.attributed_project }).Count -eq 0) -and $rows.Count -eq 4)

# --- live: the real teams ---------------------------------------------------
if (-not $OfflineOnly) {
    $h = @{ Authorization = "Bearer " + (Get-Content "$PSScriptRoot\asana_pat.txt" -Raw).Trim() }
    $dev = Get-AsanaTeamMemberNames $GAMEDEV_TEAM_GID $h
    $r = Resolve-ArtExcludedAssignees $ART_BASE_EXCLUDED $dev (Get-AsanaTeamMemberNames $ART_TEAM_GID $h)
    Check "live: GameDev - ALL Team read, $($dev.Count) members, $($r.Developers.Count) excluded" ($r.Developers.Count -gt 0)
    if ($r.Conflicts.Count) { Write-Host "      in both teams (kept in report): $($r.Conflicts -join ', ')" }
}
if ($fail) { Write-Host "`n$fail check(s) FAILED"; exit 1 } else { Write-Host "`nAll checks passed"; exit 0 }

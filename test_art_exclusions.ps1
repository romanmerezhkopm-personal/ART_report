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

# --- live: the real teams ---------------------------------------------------
if (-not $OfflineOnly) {
    $h = @{ Authorization = "Bearer " + (Get-Content "$PSScriptRoot\asana_pat.txt" -Raw).Trim() }
    $dev = Get-AsanaTeamMemberNames $GAMEDEV_TEAM_GID $h
    $r = Resolve-ArtExcludedAssignees $ART_BASE_EXCLUDED $dev (Get-AsanaTeamMemberNames $ART_TEAM_GID $h)
    Check "live: GameDev - ALL Team read, $($dev.Count) members, $($r.Developers.Count) excluded" ($r.Developers.Count -gt 0)
    if ($r.Conflicts.Count) { Write-Host "      in both teams (kept in report): $($r.Conflicts -join ', ')" }
}
if ($fail) { Write-Host "`n$fail check(s) FAILED"; exit 1 } else { Write-Host "`nAll checks passed"; exit 0 }

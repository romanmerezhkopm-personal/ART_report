# Who the ART report leaves out of every aggregation - one rule, dot-sourced by run_art_report.ps1
# and proven by test_art_exclusions.ps1.
#  - Roman Merezhko: PM oversight, not art production (Roman, 04.08.2026).
#  - Members of Asana team "GameDev - ALL Team": developers, not ART (Roman, 03.11.2026). Read live on
#    every run, so a developer added to the team later is excluded without editing this file.
#  - A person in BOTH GameDev and Art Team stays IN the report and is printed as a conflict:
#    silently dropping an artist's hours is worse than keeping one developer's.
$ART_BASE_EXCLUDED = @('Roman Merezhko')
$GAMEDEV_TEAM_GID  = "1213487151738856"
$ART_TEAM_GID      = "1213453988877387"

function Resolve-ArtExcludedAssignees([string[]]$Base, [string[]]$Developers, [string[]]$ArtTeam) {
    # 0 developers = the team read went wrong (wrong gid / auth / API), not "no developers today".
    if (-not $Developers -or $Developers.Count -eq 0) { throw "GameDev - ALL Team returned 0 members - refusing to build the report with developers included" }
    $conflicts = @($Developers | Where-Object { $ArtTeam -contains $_ } | Sort-Object -Unique)
    $devs      = @($Developers | Where-Object { $ArtTeam -notcontains $_ } | Sort-Object -Unique)
    [pscustomobject]@{ Excluded = @(@($Base) + $devs | Sort-Object -Unique); Developers = $devs; Conflicts = $conflicts }
}

function Get-AsanaTeamMemberNames([string]$TeamGid, [hashtable]$RequestHeaders) {
    # /teams/{gid}/users is not paginated (Asana returns the whole team in one response).
    @((Invoke-RestMethod "https://app.asana.com/api/1.0/teams/$TeamGid/users?opt_fields=name" -Headers $RequestHeaders).data |
      ForEach-Object { [string]$_.name })
}

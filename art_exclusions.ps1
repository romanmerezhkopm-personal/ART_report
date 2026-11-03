# Who the ART report counts, and for which hours - one rule, dot-sourced by run_art_report.ps1 and
# proven by test_art_exclusions.ps1.
#
# Excluded people (their own logged time is dropped everywhere, previous months included):
#  - Roman Merezhko: PM oversight, not art production (Roman, 04.08.2026).
#  - Maryna Riabokon: not ART (Roman, 03.11.2026).
#  - Members of Asana team "GameDev - ALL Team": developers, not ART (Roman, 03.11.2026). Read live on
#    every run, so a developer added to the team later is excluded without editing this file.
#  - A person in BOTH GameDev and Art Team stays IN the report and is printed as a conflict:
#    silently dropping an artist's hours is worse than keeping one developer's.
#
# Hours belong to whoever LOGGED them, not to the task's assignee (Roman, 03.11.2026): Maryna was the
# assignee of a CPP request whose 8 h were logged by artist Katerina Grimailo - those 8 h are Katerina's.
$ART_BASE_EXCLUDED = @('Roman Merezhko', 'Maryna Riabokon')
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

# The hours one task counts for, per person: @{ name = hours }, excluded people dropped. Every place in
# the report that needs "whose hours" reads this - header, projects, employees, comparison, trend.
# $Task is an in-memory hashtable or a time_data_*.json record. Records written before 03.11.2026 have
# no by_logger (minutes per logger): their hours fall back to the assignee, as that month counted them.
function Get-ArtPersonHours($Task, [string[]]$Excluded) {
    $bl = if ($Task -is [hashtable]) { $Task['by_logger'] } elseif ($Task.PSObject.Properties['by_logger']) { $Task.by_logger } else { $null }
    $res = @{}
    if ($null -ne $bl) {
        $names = if ($bl -is [hashtable]) { @($bl.Keys) } else { @($bl.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($n in $names) {
            $min = if ($bl -is [hashtable]) { [double]$bl[$n] } else { [double]$bl.$n }
            if ($min -gt 0 -and $Excluded -notcontains $n) { $res[$n] = $min / 60 }
        }
    } else {
        $who = [string]$Task.assignee
        $h   = [double]$Task.hours
        if ($h -gt 0 -and $Excluded -notcontains $who) { $res[$who] = $h }
    }
    return $res
}

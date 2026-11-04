# Who the ART report counts, and for which hours - one rule, dot-sourced by run_art_report.ps1 and
# proven by test_art_exclusions.ps1.
#
# Excluded people (their own logged time is dropped everywhere, previous months included):
#  - Roman Merezhko: PM oversight, not art production (Roman, 04.08.2026).
#  - Maryna Riabokon: not ART (Roman, 03.11.2026).
#  - Denys Drahanov: not an artist (Roman, 04.11.2026) - came in with the logger rule below: 3 h logged on
#    an artist's task. Find-ArtOutsideLoggers flags the next such person on every run.
#  - Members of Asana team "GameDev - ALL Team": developers, not ART (Roman, 03.11.2026). Read live on
#    every run, so a developer added to the team later is excluded without editing this file.
#  - A person in BOTH GameDev and Art Team stays IN the report and is printed as a conflict:
#    silently dropping an artist's hours is worse than keeping one developer's.
#
# Hours belong to whoever LOGGED them, not to the task's assignee (Roman, 03.11.2026): Maryna was the
# assignee of a CPP request whose 8 h were logged by artist Katerina Grimailo - those 8 h are Katerina's.
$ART_BASE_EXCLUDED = @('Roman Merezhko', 'Maryna Riabokon', 'Denys Drahanov')
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

# Projects with 0 h in the period are left out of the report (Roman, 04.11.2026): such a project exists only
# because of 0 h status rows - tasks picked by their CURRENT status (ART Ready / Ready for Test / In test),
# whatever month their time was logged in (October 2026: 16 projects, 109 rows, e.g. Obby All Games).
# Status rows inside projects WITH hours stay. External tasks are not in the project table - untouched.
# $Tasks: gid -> task (hours already without excluded people); $KeyOf: task -> project key as the table
# groups it. Removes in place, returns the left-out project keys.
function Remove-ZeroHourProjects([hashtable]$Tasks, [scriptblock]$KeyOf) {
    $projHours = @{}
    foreach ($t in $Tasks.Values) {
        if ($t.external) { continue }
        $k = & $KeyOf $t
        $projHours[$k] = [double]$projHours[$k] + [double]$t.hours
    }
    $zero = @($projHours.Keys | Where-Object { $projHours[$_] -le 0 } | Sort-Object)
    foreach ($gid in @($Tasks.Keys)) {
        $t = $Tasks[$gid]
        if (-not $t.external -and $zero -contains (& $KeyOf $t)) { $Tasks.Remove($gid) }
    }
    return $zero
}

# Counted people outside Art Team whose hours are ALL on other people's tasks (or unassigned ones) - how a
# non-artist (PO, manager) gets into the report under the logger rule. Motion Design artists are outside
# Art Team too, but log on their own tasks, so they are not flagged. Only in-portfolio tracked tasks count,
# the same set as the report's headline. Returns @{ Name; Hours } sorted by name; the run prints a WARNING.
function Find-ArtOutsideLoggers($Tasks, [string[]]$ArtTeam, [string[]]$Excluded) {
    $total = @{}; $own = @{}
    foreach ($t in $Tasks) {
        if ($t.external -or $t.is_status_based) { continue }
        $ph = Get-ArtPersonHours $t $Excluded
        foreach ($n in $ph.Keys) {
            $total[$n] = [double]$total[$n] + $ph[$n]
            if ([string]$t.assignee -eq $n) { $own[$n] = [double]$own[$n] + $ph[$n] }
        }
    }
    @($total.Keys | Where-Object { $ArtTeam -notcontains $_ -and -not $own[$_] } | Sort-Object |
      ForEach-Object { [pscustomobject]@{ Name = $_; Hours = [math]::Round($total[$_], 1) } })
}

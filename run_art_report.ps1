param(
    [Parameter(Mandatory=$true)]  [string]$Start,
    [Parameter(Mandatory=$true)]  [string]$End,
    [string]$Label = ""
)

$ErrorActionPreference = "Stop"
$BASE = "D:\project\weekly_ART_report"

# Derive filenames and labels
$periodKey = $Start.Substring(0, 7)
$jsonFile  = "$BASE\time_data_$periodKey.json"
$htmlFile  = "$BASE\ART_report_$periodKey.html"

if (-not $Label) {
    $monthNames = @('January','February','March','April','May','June',
                    'July','August','September','October','November','December')
    $d = [datetime]::ParseExact($Start, 'yyyy-MM-dd', $null)
    $Label = "$($monthNames[$d.Month - 1]) $($d.Year)"
}
$StartDisp = ([datetime]::ParseExact($Start,'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')
$EndDisp   = ([datetime]::ParseExact($End,  'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')

Write-Host "=== ART Report: $Label ($StartDisp - $EndDisp) ==="
Write-Host "JSON: $jsonFile"
Write-Host "HTML: $htmlFile"

# PAT and API setup
$PAT     = (Get-Content "$BASE\asana_pat.txt" -Raw).Trim()
$headers = @{ Authorization = "Bearer $PAT" }
$apiBase = "https://app.asana.com/api/1.0"

$ART_DIRECTION = @{
    "1213598068805254"="2D Art / UI"; "1213598068805258"="3D Art"
    "1213599181255288"="VFX";         "1213599181255292"="Animations"
    "1213910439454138"="ASO Icons";   "1213910439713691"="ASO Screenshots"
    "1213911620513682"="ASO CPP";     "1213911895502718"="ASO In App Events"
    "1213993120177405"="Banner ADS";  "1213879913329451"="CAS.product"
    # newer CAS.* projects added to the portfolio after the original 10 - each gets its own
    # dept-grid plate (Roman's request 03.09.2026: was folded into one "CAS Requests" plate,
    # no longer - the 4 CAS.* projects are distinct teams/workstreams, not one department)
    "1216704431904924"="CAS.the_rest"; "1216704431904918"="CAS.ads"; "1216704431904914"="CAS.socialmedia"
    # portfolio grew from 13 to 15 projects between the 02.08 and 03.09.2026 runs - found live
    # via the API while regenerating this report (was silently dropping their tasks from every
    # dept-grid plate, since Add-SubtasksRecursive's Write-Host used $ART_DIRECTION[$projGid]
    # but nothing downstream failed loudly). Each new project gets its own plate, same as every
    # other single-project department here.
    "1217850380511462"="TechART"; "1213911862802481"="Feature Graphics"
}

# ART portfolio membership is fetched live (not hardcoded) so newly added/removed projects are
# picked up automatically - Roman's request 04.08.2026 after the portfolio grew from 10 to 13 projects.
$ART_PORTFOLIO_GID = "1213829329062998"
$portfolioItems = [ordered]@{}
try {
    $resp = Invoke-RestMethod "$apiBase/portfolios/$ART_PORTFOLIO_GID/items?opt_fields=gid,name,resource_type,archived&limit=100" -Headers $headers
    foreach ($item in $resp.data) {
        if ($item.resource_type -eq "project" -and -not [bool]$item.archived) { $portfolioItems[$item.gid] = $item.name }
    }
} catch { Write-Host "  ERROR fetching ART portfolio: $_" }
$ART_GIDs = @($portfolioItems.Keys)
if ($ART_GIDs.Count -eq 0) {
    Write-Host "  WARNING: ART portfolio fetch returned 0 projects, falling back to the last-known hardcoded list"
    $ART_GIDs = @("1213598068805254","1213598068805258","1213599181255288","1213599181255292",
                  "1213910439454138","1213910439713691","1213911620513682","1213911895502718",
                  "1213993120177405","1213879913329451","1216704431904924","1216704431904918","1216704431904914")
}
Write-Host "  ART portfolio: $($ART_GIDs.Count) projects"

# Executable check (added 03.09.2026 after TechART/Feature Graphics were found missing from
# $ART_DIRECTION live): the portfolio fetch above protects Step 1 (which projects get scanned),
# but $ART_DIRECTION is a separate hardcoded gid->name map nothing keeps in sync automatically.
# A portfolio project missing here doesn't crash anything - its tasks just silently never appear
# in any dept-grid card. Fail loudly and early instead of a quiet Write-Host with a blank name.
$missingFromDirMap = @($ART_GIDs | Where-Object { -not $ART_DIRECTION.ContainsKey($_) })
if ($missingFromDirMap.Count -gt 0) {
    Write-Host "  !!! WARNING: $($missingFromDirMap.Count) portfolio project(s) missing from `$ART_DIRECTION - their tasks will NOT appear in any dept-grid card:"
    foreach ($mg in $missingFromDirMap) {
        $mgName = if ($portfolioItems.Contains($mg)) { $portfolioItems[$mg] } else { "(name unknown)" }
        Write-Host "      $mg  $mgName"
    }
    Write-Host "  !!! Add these to `$ART_DIRECTION and `$deptOrder near the top of this script before trusting this report's direction breakdown."
}
$ART_GID_SET = @{}
foreach ($g in $ART_GIDs) { $ART_GID_SET[$g] = $true }

$STATUS_FIELD_GID = "1213529841611701"
$TARGET_STATUSES  = @{
    "1214732680333428" = "ART Ready"
    "1213906104809741" = "Ready for Test"
    "1213634616829012" = "In test"
}

# Excluded from all report aggregations (PM oversight, not art production work) - Roman's request 04.08.2026
$EXCLUDED_ASSIGNEES = @('Roman Merezhko')

# ============================================================
# STEP 1 - Collect tasks (+ all subtasks, any depth) from every ART-portfolio project
# ============================================================
Write-Host "`n[1/3] Collecting tasks from $($ART_GIDs.Count) ART portfolio projects..."
$allTasks = @{}

# Subtasks aren't project members (/projects/{gid}/tasks never returns them), so every task
# collected below is expanded recursively. Subtasks inherit the top-level ancestor's project
# membership - this makes every downstream step (hours, dept-grid, attribution, CAS-vs-game,
# employees) treat subtasks exactly like any other task, under the same conditions everywhere.
# Roman's request 04.08.2026: no more per-section inconsistency in what counts as "a task".
function Add-SubtasksRecursive([string]$parentGid, [array]$inheritedMems) {
    try {
        $resp = Invoke-RestMethod "$apiBase/tasks/$parentGid/subtasks?opt_fields=gid,name,assignee.name,permalink_url,custom_fields.gid,custom_fields.enum_value.gid&limit=100" -Headers $headers
        foreach ($st in $resp.data) {
            if ($allTasks.ContainsKey($st.gid)) { continue }
            $sStatusGid = ""
            if ($st.PSObject.Properties['custom_fields'] -and $st.custom_fields) {
                $sf = $st.custom_fields | Where-Object { $_.gid -eq $STATUS_FIELD_GID }
                if ($sf -and $sf.enum_value -and $sf.enum_value.gid) { $sStatusGid = $sf.enum_value.gid }
            }
            $allTasks[$st.gid] = @{
                name          = $st.name
                assignee      = if ($st.PSObject.Properties['assignee'] -and $st.assignee -and $st.assignee.name) { $st.assignee.name } else { "Unassigned" }
                permalink_url = if ($st.PSObject.Properties['permalink_url']) { $st.permalink_url } else { "" }
                memberships   = $inheritedMems
                status_gid    = $sStatusGid
                completed     = $false
                completed_at  = ""
                isSub         = $true
            }
            Add-SubtasksRecursive $st.gid $inheritedMems
        }
    } catch {}
}

foreach ($projGid in $ART_GIDs) {
    $offset   = $null
    $newCount = 0
    do {
        $url = "$apiBase/projects/$projGid/tasks?opt_fields=gid,name,assignee.name,memberships.project.gid,memberships.project.name,permalink_url,custom_fields.gid,custom_fields.enum_value.gid,completed,completed_at&limit=100"
        if ($offset) { $url += "&offset=$offset" }
        try {
            $resp = Invoke-RestMethod $url -Headers $headers
            foreach ($task in $resp.data) {
                if (-not $allTasks.ContainsKey($task.gid)) {
                    $mems = @()
                    if ($task.memberships) {
                        foreach ($m in $task.memberships) {
                            if ($m.PSObject.Properties['project'] -and $m.project -and $m.project.gid) {
                                $mems += @{ gid=[string]$m.project.gid; name=[string]$m.project.name }
                            }
                        }
                    }
                    $statusGid = ""
                    if ($task.PSObject.Properties['custom_fields'] -and $task.custom_fields) {
                        $sf = $task.custom_fields | Where-Object { $_.gid -eq $STATUS_FIELD_GID }
                        if ($sf -and $sf.enum_value -and $sf.enum_value.gid) { $statusGid = $sf.enum_value.gid }
                    }
                    $allTasks[$task.gid] = @{
                        name          = $task.name
                        assignee      = if ($task.PSObject.Properties['assignee'] -and $task.assignee -and $task.assignee.name) { $task.assignee.name } else { "Unassigned" }
                        permalink_url = if ($task.PSObject.Properties['permalink_url']) { $task.permalink_url } else { "" }
                        memberships   = $mems
                        status_gid    = $statusGid
                        completed     = [bool]$task.completed
                        completed_at  = if ($task.PSObject.Properties['completed_at'] -and $task.completed_at) { [string]$task.completed_at } else { "" }
                        isSub         = $false
                    }
                    $newCount++
                    Add-SubtasksRecursive $task.gid $mems
                }
            }
            $offset = if ($resp.next_page -and $resp.next_page.offset) { $resp.next_page.offset } else { $null }
        } catch {
            Write-Host "  ERROR project $projGid : $_"
            $offset = $null
        }
    } while ($offset)
    Write-Host "  $($ART_DIRECTION[$projGid]): +$newCount  (total: $($allTasks.Count))"
}
Write-Host "Total unique tasks: $($allTasks.Count)"

# ============================================================
# STEP 2 - Get time_tracking_entries filtered by period
# ============================================================
Write-Host "`n[2/3] Fetching time entries for $StartDisp - $EndDisp ..."
$taskMinutes = @{}
$taskLoggers = @{}
$i = 0
foreach ($gid in @($allTasks.Keys)) {
    $i++
    if ($i % 50 -eq 0) { Write-Host "  [$i / $($allTasks.Count)]..." }
    try {
        $url  = "$apiBase/tasks/$gid/time_tracking_entries?opt_fields=duration_minutes,entered_on,created_by.name&limit=100"
        $resp = Invoke-RestMethod $url -Headers $headers
        $tot  = 0
        $loggers = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($e in $resp.data) {
            if ($e.entered_on -and $e.entered_on -ge $Start -and $e.entered_on -le $End) {
                $tot += [int]$e.duration_minutes
                if ($e.created_by -and $e.created_by.name) { [void]$loggers.Add([string]$e.created_by.name) }
            }
        }
        if ($tot -gt 0) { $taskMinutes[$gid] = $tot; $taskLoggers[$gid] = ($loggers -join ', ') }
    } catch {}
}
Write-Host "Tasks with tracked time in period: $($taskMinutes.Count)"

# ============================================================
# STEP 2.3 - Add tasks with target statuses (ART Ready / Ready for Test / In test)
# ============================================================
$statusAddedCount = 0
foreach ($gid in @($allTasks.Keys)) {
    if ($taskMinutes.ContainsKey($gid)) { continue }  # already has tracked time
    $sGid = $allTasks[$gid].status_gid
    if ($TARGET_STATUSES.ContainsKey($sGid)) {
        $taskMinutes[$gid] = 0
        $allTasks[$gid].is_status_based = $true
        $allTasks[$gid].status_name     = $TARGET_STATUSES[$sGid]
        $statusAddedCount++
    }
}
Write-Host "Tasks added by status (0 time tracked): $statusAddedCount"

# ============================================================
# STEP 2.5 - Art Team members + their tasks outside ART portfolio
# ============================================================
$TEAM_GID = "1213453988877387"
$WS_GID   = "1210983682540893"
$externalGids = @{}
$teamMembers  = @{}
Write-Host "`n[2.5] Fetching Art Team members and external tasks..."
try {
    $resp = Invoke-RestMethod "$apiBase/teams/$TEAM_GID/users?opt_fields=name&limit=100" -Headers $headers
    foreach ($u in $resp.data) { $teamMembers[$u.gid] = $u.name }
} catch { Write-Host "  ERROR fetching team members: $_" }
foreach ($exGid in @($teamMembers.Keys)) {
    if ($EXCLUDED_ASSIGNEES -contains $teamMembers[$exGid]) { $teamMembers.Remove($exGid) }
}
Write-Host "  Team members: $($teamMembers.Count)"

# Asana's tasks/search endpoint never paginates past 100 results (confirmed 14.08.2026 while
# building /3month_ART_report: a bare 100-limit query silently truncates for high-volume assignees,
# with no next_page offered). Adaptively split the date range in half whenever a sub-query returns
# exactly 100, merging results, until every sub-range is under the cap (or hits single-day
# granularity, logged as a WARNING - genuine 100+/day from one person is not expected in practice).
function Get-CandidateTasksAdaptive([string]$uGid, [string]$rangeStart, [string]$rangeEndExclusive, [hashtable]$acc, [int]$depth) {
    $url = "$apiBase/workspaces/$WS_GID/tasks/search?assignee.any=$uGid&modified_on.after=$rangeStart&modified_on.before=$rangeEndExclusive&opt_fields=gid,name,assignee.name,memberships.project.gid,memberships.project.name,permalink_url&limit=100"
    try { $resp = Invoke-RestMethod $url -Headers $headers } catch { Write-Host "  search failed for range $rangeStart..$rangeEndExclusive : $_"; return }
    $items = @($resp.data)
    if ($items.Count -eq 100 -and $depth -lt 12) {
        $sD = [datetime]::ParseExact($rangeStart,'yyyy-MM-dd',$null)
        $eD = [datetime]::ParseExact($rangeEndExclusive,'yyyy-MM-dd',$null)
        $spanDays = ($eD - $sD).Days
        if ($spanDays -le 1) {
            foreach ($task in $items) { $acc[$task.gid] = $task }
            Write-Host "  WARNING: $uGid hit 100 results on a single day ($rangeStart) - accepting as-is"
            return
        }
        $mid = $sD.AddDays([math]::Floor($spanDays / 2)).ToString('yyyy-MM-dd')
        Get-CandidateTasksAdaptive $uGid $rangeStart $mid $acc ($depth + 1)
        Get-CandidateTasksAdaptive $uGid $mid $rangeEndExclusive $acc ($depth + 1)
    } else {
        foreach ($task in $items) { $acc[$task.gid] = $task }
    }
}

$candidates = @{}
$searchEndExclusive = (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
foreach ($uGid in $teamMembers.Keys) {
    $rawTasks = @{}
    Get-CandidateTasksAdaptive $uGid $Start $searchEndExclusive $rawTasks 0
    foreach ($task in $rawTasks.Values) {
        if ($allTasks.ContainsKey($task.gid) -or $candidates.ContainsKey($task.gid)) { continue }
        $mems = @()
        if ($task.memberships) {
            foreach ($m in $task.memberships) {
                if ($m.PSObject.Properties['project'] -and $m.project -and $m.project.gid) {
                    $mems += @{ gid=[string]$m.project.gid; name=[string]$m.project.name }
                }
            }
        }
        $candidates[$task.gid] = @{
            name          = $task.name
            assignee      = if ($task.PSObject.Properties['assignee'] -and $task.assignee -and $task.assignee.name) { $task.assignee.name } else { $teamMembers[$uGid] }
            permalink_url = if ($task.PSObject.Properties['permalink_url']) { $task.permalink_url } else { "" }
            memberships   = $mems
        }
    }
}
Write-Host "  External candidate tasks: $($candidates.Count)"

$j = 0
foreach ($gid in @($candidates.Keys)) {
    $j++
    if ($j % 50 -eq 0) { Write-Host "  [$j / $($candidates.Count)]..." }
    try {
        $url  = "$apiBase/tasks/$gid/time_tracking_entries?opt_fields=duration_minutes,entered_on&limit=100"
        $resp = Invoke-RestMethod $url -Headers $headers
        $tot  = 0
        foreach ($e in $resp.data) {
            if ($e.entered_on -and $e.entered_on -ge $Start -and $e.entered_on -le $End) {
                $tot += [int]$e.duration_minutes
            }
        }
        if ($tot -gt 0) {
            $allTasks[$gid]     = $candidates[$gid]
            $taskMinutes[$gid]  = $tot
            $externalGids[$gid] = $true
        }
    } catch {}
}
Write-Host "  External tasks with tracked time in period: $($externalGids.Count)"

# Attribute tasks to projects
Write-Host "[3/3] Attributing and saving JSON..."
$processed = @{}
foreach ($gid in $taskMinutes.Keys) {
    $task = $allTasks[$gid]
    $isExt = $externalGids.ContainsKey($gid)
    $artDir = "Unknown"
    foreach ($m in $task.memberships) {
        if ($ART_DIRECTION.ContainsKey($m.gid)) { $artDir = $ART_DIRECTION[$m.gid]; break }
    }
    if ($isExt) { $artDir = "External" }
    $attrProject = $null
    foreach ($m in $task.memberships) {
        if (-not $ART_GID_SET.ContainsKey($m.gid)) { $attrProject = $m.name; break }
    }
    if (-not $attrProject) {
        foreach ($m in $task.memberships) {
            if ($ART_GID_SET.ContainsKey($m.gid)) { $attrProject = $m.name; break }
        }
    }
    if (-not $attrProject) { $attrProject = if ($isExt) { "No project" } else { "Unknown" } }

    $isSB = $allTasks[$gid].is_status_based -eq $true
    $processed[$gid] = @{
        name               = $task.name
        assignee           = $task.assignee
        permalink_url      = $task.permalink_url
        art_direction      = $artDir
        attributed_project = $attrProject
        external           = $isExt
        minutes            = $taskMinutes[$gid]
        hours              = [math]::Round($taskMinutes[$gid] / 60, 2)
        is_status_based    = $isSB
        status_name        = if ($isSB) { $allTasks[$gid].status_name } else { "" }
    }
}
$processed | ConvertTo-Json -Depth 10 | Out-File $jsonFile -Encoding utf8
Write-Host "Saved: $jsonFile  ($($processed.Count) tasks)"

# ============================================================
# STEP 3.7 - CAS (internal requests) vs game-project (ART backlog) breakdown
# ============================================================
Write-Host "`n[3.7] CAS vs game-project breakdown (tasks with tracking in period)..."

# Reuse the ART portfolio membership already fetched at the top of the script (drives $ART_GIDs
# too). A project counts as "CAS" if its name starts with "CAS" - everything else is "game" work.
$CAS_LABELS = [ordered]@{}
$BACKLOG_LABELS = [ordered]@{}
foreach ($gid in $portfolioItems.Keys) {
    $nm = $portfolioItems[$gid]
    if ($nm -like "CAS*") { $CAS_LABELS[$gid] = $nm } else { $BACKLOG_LABELS[$gid] = $nm }
}
Write-Host "  ART portfolio: $($CAS_LABELS.Count) CAS + $($BACKLOG_LABELS.Count) game projects"

# Projects in the portfolio that the main 10-project pipeline (Steps 1-2) doesn't already cover
# need their own fresh fetch (tasks + time entries).
$portfolioExtraGids = @($CAS_LABELS.Keys) + @($BACKLOG_LABELS.Keys) | Where-Object { -not $ART_GID_SET.ContainsKey($_) }
$casExtraTasks = @{}
foreach ($projGid in $portfolioExtraGids) {
    $offset = $null
    do {
        $url = "$apiBase/projects/$projGid/tasks?opt_fields=gid,name,completed,completed_at,permalink_url&limit=100"
        if ($offset) { $url += "&offset=$offset" }
        try {
            $resp = Invoke-RestMethod $url -Headers $headers
            foreach ($task in $resp.data) {
                $casExtraTasks[$task.gid] = @{
                    name          = $task.name
                    projGid       = $projGid
                    completed     = [bool]$task.completed
                    completed_at  = if ($task.PSObject.Properties['completed_at'] -and $task.completed_at) { [string]$task.completed_at } else { "" }
                    permalink_url = if ($task.PSObject.Properties['permalink_url']) { $task.permalink_url } else { "" }
                }
            }
            $offset = if ($resp.next_page -and $resp.next_page.offset) { $resp.next_page.offset } else { $null }
        } catch { Write-Host "  ERROR portfolio project $projGid : $_"; $offset = $null }
    } while ($offset)
}
Write-Host "  Extra portfolio projects: $($portfolioExtraGids.Count) projects, $($casExtraTasks.Count) tasks"

$casExtraMinutes = @{}
$casExtraLoggers = @{}
foreach ($gid in @($casExtraTasks.Keys)) {
    try {
        $url  = "$apiBase/tasks/$gid/time_tracking_entries?opt_fields=duration_minutes,entered_on,created_by.name&limit=100"
        $resp = Invoke-RestMethod $url -Headers $headers
        $tot  = 0
        $loggers = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($e in $resp.data) {
            if ($e.entered_on -and $e.entered_on -ge $Start -and $e.entered_on -le $End) {
                $tot += [int]$e.duration_minutes
                if ($e.created_by -and $e.created_by.name) { [void]$loggers.Add([string]$e.created_by.name) }
            }
        }
        if ($tot -gt 0) { $casExtraMinutes[$gid] = $tot; $casExtraLoggers[$gid] = ($loggers -join ', ') }
    } catch {}
}

$rawProjStats = @{}
foreach ($gid in $CAS_LABELS.Keys)      { $rawProjStats[$gid] = @{ name = $CAS_LABELS[$gid];      total = 0; hoursMin = 0; tasks = [System.Collections.Generic.List[object]]::new() } }
foreach ($gid in $BACKLOG_LABELS.Keys)  { $rawProjStats[$gid] = @{ name = $BACKLOG_LABELS[$gid];  total = 0; hoursMin = 0; tasks = [System.Collections.Generic.List[object]]::new() } }

# Unified with the rest of the report (header stat / trend chart): a task counts if it has actual
# tracked time in the period (taskMinutes > 0 - Step 2.3's zero-minute status-based entries excluded),
# same criterion as "Задач с трекингом". CAS.product + the 9 backlog projects reuse the already-
# collected full task set (Step 1) and period-filtered time entries (Step 2).
foreach ($gid in @($allTasks.Keys)) {
    $t = $allTasks[$gid]
    if ($EXCLUDED_ASSIGNEES -contains $t.assignee) { continue }
    if (-not ($taskMinutes.ContainsKey($gid) -and $taskMinutes[$gid] -gt 0)) { continue }
    $homeGid = $null
    foreach ($m in $t.memberships) {
        if ($rawProjStats.ContainsKey($m.gid)) { $homeGid = $m.gid; break }
    }
    if (-not $homeGid) { continue }
    $rawProjStats[$homeGid].total++
    $rawProjStats[$homeGid].hoursMin += $taskMinutes[$gid]
    $logger = if ($taskLoggers.ContainsKey($gid)) { $taskLoggers[$gid] } else { "" }
    $isSub  = [bool]$t.isSub
    [void]$rawProjStats[$homeGid].tasks.Add(@{ name = $t.name; url = $t.permalink_url; hours = [math]::Round($taskMinutes[$gid] / 60.0, 2); logger = $logger; isSub = $isSub })
}

# the portfolio projects outside the main pipeline (defensive fallback - currently always empty
# since $ART_GIDs already covers every portfolio project; kept in case the portfolio ever adds a
# project this run's own fetch races past)
foreach ($gid in @($casExtraTasks.Keys)) {
    $t = $casExtraTasks[$gid]
    if (-not ($casExtraMinutes.ContainsKey($gid) -and $casExtraMinutes[$gid] -gt 0)) { continue }
    $rawProjStats[$t.projGid].total++
    $rawProjStats[$t.projGid].hoursMin += $casExtraMinutes[$gid]
    $logger = if ($casExtraLoggers.ContainsKey($gid)) { $casExtraLoggers[$gid] } else { "" }
    [void]$rawProjStats[$t.projGid].tasks.Add(@{ name = $t.name; url = $t.permalink_url; hours = [math]::Round($casExtraMinutes[$gid] / 60.0, 2); logger = $logger })
}

$casTotalCount = 0; $casHoursTotal = 0.0
foreach ($gid in $CAS_LABELS.Keys) { $casTotalCount += $rawProjStats[$gid].total; $casHoursTotal += $rawProjStats[$gid].hoursMin / 60.0 }
$backlogTotalCount = 0; $backlogHoursTotal = 0.0
foreach ($gid in $BACKLOG_LABELS.Keys) { $backlogTotalCount += $rawProjStats[$gid].total; $backlogHoursTotal += $rawProjStats[$gid].hoursMin / 60.0 }
Write-Host "  CAS: $casTotalCount tasks / $([math]::Round($casHoursTotal,2)) h  |  Backlog: $backlogTotalCount tasks / $([math]::Round($backlogHoursTotal,2)) h"

# ============================================================
# STEP 4 - Generate HTML
# ============================================================
Write-Host "`n[4/4] Generating HTML report..."

$rawJson = Get-Content $jsonFile -Raw -Encoding utf8
$dataObj = $rawJson | ConvertFrom-Json
$tasks2  = @{}
foreach ($prop in $dataObj.PSObject.Properties) {
    $t = $prop.Value
    if ($EXCLUDED_ASSIGNEES -contains [string]$t.assignee) { continue }
    $tasks2[$prop.Name] = @{
        name               = [string]$t.name
        assignee           = [string]$t.assignee
        permalink_url      = [string]$t.permalink_url
        art_direction      = [string]$t.art_direction
        attributed_project = [string]$t.attributed_project
        external           = [bool]$t.external
        hours              = [double]$t.hours
        is_status_based    = if ($t.PSObject.Properties['is_status_based']) { [bool]$t.is_status_based } else { $false }
        status_name        = if ($t.PSObject.Properties['status_name']) { [string]$t.status_name } else { "" }
    }
}

function Esc([string]$s) { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
function Clean-Project([string]$name) {
    $c = $name -replace '\s*:?\s*\[[^\]]*\]','' -replace '\s*\([^\)]*\)\s*$',''
    $c = $c.Trim()
    if ($c -eq 'ASO Custom Product Pages') { return 'ASO CPP' }
    return $c
}
function Art-Pill([string]$dir) {
    switch ($dir) {
        '2D Art / UI'       { '<span class="art-pill art-2d">2D Art</span>' }
        '3D Art'            { '<span class="art-pill art-3d">3D Art</span>' }
        'VFX'               { '<span class="art-pill art-vfx">VFX</span>' }
        'Animations'        { '<span class="art-pill art-anim">Anim</span>' }
        'ASO Icons'         { '<span class="art-pill art-aso">ASO Icons</span>' }
        'ASO Screenshots'   { '<span class="art-pill art-aso">ASO SS</span>' }
        'ASO CPP'           { '<span class="art-pill art-aso">ASO CPP</span>' }
        'ASO In App Events' { '<span class="art-pill art-aso">ASO Events</span>' }
        'Banner ADS'        { '<span class="art-pill art-ban">Banner</span>' }
        'CAS.product'       { '<span class="art-pill art-cas">CAS.product</span>' }
        'CAS.ads'           { '<span class="art-pill art-cas">CAS.ads</span>' }
        'CAS.socialmedia'   { '<span class="art-pill art-cas">CAS.socialmedia</span>' }
        'CAS.the_rest'      { '<span class="art-pill art-cas">CAS.the_rest</span>' }
        'TechART'           { '<span class="art-pill art-3d">TechART</span>' }
        'Feature Graphics'  { '<span class="art-pill art-ban">Feature Gfx</span>' }
        'External'          { '<span class="art-pill" style="background:#edf2f7;color:#718096;">&#1042;&#1085;&#1077; ART</span>' }
        default             { '<span class="art-pill">' + (Esc $dir) + '</span>' }
    }
}
function Fmt([double]$h) {
    if ($h -eq [math]::Floor($h)) { "$([int]$h)" } else { "$([math]::Round($h,2))" }
}
function Status-Pill([string]$sn) {
    switch ($sn) {
        'ART Ready'      { '<span class="status-pill sp-art-ready">ART Ready</span>' }
        'Ready for Test' { '<span class="status-pill sp-ready-test">Ready for Test</span>' }
        'In test'        { '<span class="status-pill sp-in-test">In test</span>' }
        default          { '' }
    }
}
function Build-TrendSvg([array]$points) {
    $W = 1000; $H = 260
    $padL = 50; $padR = 30; $padT = 20; $padB = 40
    $plotW = $W - $padL - $padR
    $plotH = $H - $padT - $padB
    $vmax = ($points | ForEach-Object { $_.Value } | Measure-Object -Maximum).Maximum
    if ($vmax -le 0) { $vmax = 1 }
    $top = 50 * ([math]::Floor($vmax / 50) + 1)
    $n = $points.Count
    $step = if ($n -gt 1) { $plotW / ($n - 1) } else { 0 }

    $svg = [System.Collections.Generic.List[string]]::new()
    [void]$svg.Add('<svg viewBox="0 0 ' + $W + ' ' + $H + '" width="100%" height="' + $H + '" role="img" aria-label="&#1044;&#1080;&#1085;&#1072;&#1084;&#1080;&#1082;&#1072; &#1079;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084; &#1087;&#1086; &#1084;&#1077;&#1089;&#1103;&#1094;&#1072;&#1084;">')

    for ($g = 0; $g -le 4; $g++) {
        $val = [math]::Round($top * $g / 4)
        $y = $padT + $plotH - ($val / $top * $plotH)
        [void]$svg.Add('<line x1="' + $padL + '" y1="' + [math]::Round($y,1) + '" x2="' + ($W-$padR) + '" y2="' + [math]::Round($y,1) + '" stroke="#e2e8f0" stroke-width="1"/>')
        [void]$svg.Add('<text x="' + ($padL-10) + '" y="' + [math]::Round($y+4,1) + '" font-size="11" fill="#a0aec0" text-anchor="end" font-family="-apple-system,Segoe UI,sans-serif">' + $val + '</text>')
    }

    $pts = @()
    for ($i = 0; $i -lt $n; $i++) {
        $px = $padL + $step * $i
        $py = $padT + $plotH - ($points[$i].Value / $top * $plotH)
        $pts += @{x=$px; y=$py; label=$points[$i].Label; v=$points[$i].Value}
    }

    $pathD = 'M ' + (($pts | ForEach-Object { [string][math]::Round($_.x,1) + ',' + [string][math]::Round($_.y,1) }) -join ' L ')
    [void]$svg.Add('<path d="' + $pathD + '" fill="none" stroke="#667eea" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>')

    foreach ($p in $pts) {
        $xr = [math]::Round($p.x,1); $yr = [math]::Round($p.y,1)
        [void]$svg.Add('<circle cx="' + $xr + '" cy="' + $yr + '" r="5" fill="#667eea" stroke="white" stroke-width="2"><title>' + $p.label + ': ' + $p.v + ' &#1079;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</title></circle>')
        [void]$svg.Add('<text x="' + $xr + '" y="' + [math]::Round($p.y-14,1) + '" font-size="13" font-weight="700" fill="#2d3748" text-anchor="middle" font-family="-apple-system,Segoe UI,sans-serif">' + $p.v + '</text>')
        [void]$svg.Add('<text x="' + $xr + '" y="' + ($H-10) + '" font-size="12" fill="#718096" text-anchor="middle" font-family="-apple-system,Segoe UI,sans-serif">' + $p.label + '</text>')
    }

    [void]$svg.Add('</svg>')
    return ($svg -join '')
}

# Aggregate
$byProject   = @{}
$byDirection = @{}
$byAssignee  = @{}
foreach ($gid in $tasks2.Keys) {
    $t    = $tasks2[$gid]
    $proj = Clean-Project $t.attributed_project
    $dir  = $t.art_direction
    $who  = $t.assignee
    if (-not $t.external) {
        if (-not $byProject.ContainsKey($proj)) {
            $byProject[$proj] = @{ tasks=[System.Collections.Generic.List[object]]::new(); hours=0.0; dirs=@{} }
        }
        $byProject[$proj].tasks.Add(@{gid=$gid;name=$t.name;assignee=$t.assignee;url=$t.permalink_url;dir=$dir;hours=$t.hours;is_status_based=$t.is_status_based;status_name=$t.status_name})
        $byProject[$proj].hours += $t.hours
        $byProject[$proj].dirs[$dir] = 1
        if (-not $byDirection.ContainsKey($dir)) { $byDirection[$dir] = 0.0 }
        $byDirection[$dir] += $t.hours
    }
    if (-not $byAssignee.ContainsKey($who)) {
        $byAssignee[$who] = @{ tasks=[System.Collections.Generic.List[object]]::new(); hours=0.0 }
    }
    $byAssignee[$who].tasks.Add(@{gid=$gid;name=$t.name;url=$t.permalink_url;dir=$dir;hours=$t.hours;proj=$proj;external=$t.external;is_status_based=$t.is_status_based;status_name=$t.status_name})
    $byAssignee[$who].hours += $t.hours
}

$totalH    = 0.0
$totalT    = 0
$totalSB   = 0
foreach ($g in $tasks2.Keys) {
    if (-not $tasks2[$g].external) {
        if ($tasks2[$g].is_status_based) { $totalSB++ }
        else { $totalH += $tasks2[$g].hours; $totalT++ }
    }
}
$empTotalH = 0.0
foreach ($v in $byAssignee.Values) { $empTotalH += $v.hours }
$totalP    = $byProject.Count
$totalD    = $byDirection.Count
$totalHInt = [math]::Round($totalH)

$sortedProj      = $byProject.GetEnumerator()  | Sort-Object { $_.Value.hours } -Descending
$sortedAssignees = $byAssignee.GetEnumerator() | Sort-Object { $_.Value.hours } -Descending
$maxH = 0.0
foreach ($v in $byProject.Values) { if ($v.hours -gt $maxH) { $maxH = $v.hours } }

$deptOrder = @('3D Art','2D Art / UI','Animations','VFX','TechART',
               'CAS.product','CAS.ads','CAS.socialmedia','CAS.the_rest',
               'ASO Screenshots','ASO Icons','ASO CPP','ASO In App Events','Banner ADS','Feature Graphics')
$barColors = @('#667eea','#764ba2','#f093fb','#4facfe','#f5576c','#fd746c','#43e97b',
               '#fa709a','#30cfd0','#a8edea','#feb692','#96fbc4','#5ee7df','#b490ca','#fda085')

# Build HTML
$L = [System.Collections.Generic.List[string]]::new()

[void]$L.Add('<!DOCTYPE html>')
[void]$L.Add('<html lang="ru">')
[void]$L.Add('<head>')
[void]$L.Add('<meta charset="UTF-8">')
[void]$L.Add('<title>ART Department Report &#8212; ' + $Label + '</title>')
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
[void]$L.Add('.notice-g { background:#f0fff4; border-left:4px solid #38a169; padding:12px 16px; border-radius:6px; margin-bottom:24px; font-size:13px; color:#276749; }')
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
[void]$L.Add('.art-types { display:flex; flex-wrap:wrap; gap:4px; }')
[void]$L.Add('.art-pill { display:inline-block; padding:1px 7px; border-radius:8px; font-size:11px; font-weight:500; }')
[void]$L.Add('.art-2d { background:#e9d8fd; color:#553c9a; }')
[void]$L.Add('.art-3d { background:#bee3f8; color:#2a69ac; }')
[void]$L.Add('.art-vfx { background:#c6f6d5; color:#276749; }')
[void]$L.Add('.art-anim { background:#feebc8; color:#7b341e; }')
[void]$L.Add('.art-aso { background:#fed7e2; color:#97266d; }')
[void]$L.Add('.art-ban { background:#e2e8f0; color:#4a5568; }')
[void]$L.Add('.art-cas { background:#e6fffa; color:#234e52; }')
[void]$L.Add('.status-pill { display:inline-block; padding:1px 7px; border-radius:8px; font-size:10px; font-weight:600; margin-left:5px; vertical-align:middle; }')
[void]$L.Add('.sp-art-ready { background:#c6f6d5; color:#276749; }')
[void]$L.Add('.sp-ready-test { background:#bee3f8; color:#2a69ac; }')
[void]$L.Add('.sp-in-test { background:#feebc8; color:#7b341e; }')
[void]$L.Add('.status-row td { background:#fafffe; }')
[void]$L.Add('.dist-chart { display:flex; flex-direction:column; gap:10px; }')
[void]$L.Add('.dist-row { display:flex; align-items:center; gap:12px; }')
[void]$L.Add('.dist-label { width:240px; font-size:13px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; flex-shrink:0; }')
[void]$L.Add('.dist-bar-wrap { flex:1; background:#edf2f7; border-radius:4px; height:20px; }')
[void]$L.Add('.dist-bar { height:20px; border-radius:4px; display:flex; align-items:center; padding-left:8px; font-size:11px; color:white; font-weight:600; white-space:nowrap; min-width:36px; }')
[void]$L.Add('.dist-val { width:70px; text-align:right; font-size:12px; color:#718096; flex-shrink:0; }')
[void]$L.Add('details.proj-row { margin-bottom:8px; border:1px solid #e2e8f0; border-radius:8px; overflow:hidden; }')
[void]$L.Add('details.proj-row > summary { cursor:pointer; padding:10px 14px; background:#f7f8fc; list-style:none; display:flex; align-items:center; gap:14px; }')
[void]$L.Add('details.proj-row > summary::-webkit-details-marker { display:none; }')
[void]$L.Add('details.proj-row > summary::after { content:"\25B8"; color:#a0aec0; font-size:12px; }')
[void]$L.Add('details.proj-row[open] > summary { border-radius:8px 8px 0 0; }')
[void]$L.Add('details.proj-row[open] > summary::after { content:"\25BE"; }')
[void]$L.Add('.proj-row-rank { flex-shrink:0; width:22px; }')
[void]$L.Add('.proj-row-name { flex:1; min-width:160px; display:flex; align-items:center; gap:8px; flex-wrap:wrap; }')
[void]$L.Add('.proj-row-tasks { flex-shrink:0; width:64px; text-align:center; color:#718096; font-size:13px; }')
[void]$L.Add('.proj-row-bar-wrap { flex-shrink:0; width:180px; background:#edf2f7; border-radius:4px; height:20px; }')
[void]$L.Add('.proj-row-bar { height:20px; border-radius:4px; display:flex; align-items:center; padding-left:8px; font-size:11px; color:white; font-weight:600; white-space:nowrap; min-width:32px; }')
[void]$L.Add('.proj-row-hours { flex-shrink:0; width:80px; text-align:right; font-weight:700; font-size:15px; color:#2d3748; }')
[void]$L.Add('.proj-row-summary-line { font-size:13px; color:#718096; margin-bottom:12px; }')
[void]$L.Add('.proj-dir-groups { padding:10px; }')
[void]$L.Add('.proj-dir-groups details { border:1px solid #e2e8f0; border-radius:8px; overflow:hidden; }')
[void]$L.Add('.proj-dir-groups details summary { background:#eef1f8; }')
[void]$L.Add('.proj-dir-total { padding:10px 14px; font-weight:700; background:#f7f8fc; border-top:1px solid #e2e8f0; font-size:13px; }')
[void]$L.Add('.cmp-header { display:flex; align-items:center; gap:8px; padding:0 14px 8px; }')
[void]$L.Add('.cmp-header .cmp-col { font-size:11px; font-weight:600; color:#718096; text-transform:uppercase; letter-spacing:.5px; }')
[void]$L.Add('.cmp-header .cmp-col small { font-weight:400; text-transform:none; letter-spacing:normal; }')
[void]$L.Add('.cmp-row summary { gap:8px; }')
[void]$L.Add('.cmp-col { flex:1; text-align:center; font-size:13px; }')
[void]$L.Add('.cmp-col.cmp-name { flex:1.6; text-align:left; }')
[void]$L.Add('.dept-grid { display:grid; grid-template-columns:repeat(5,1fr); gap:12px; }')
[void]$L.Add('.dept-card { background:#f7f8fc; border-radius:8px; padding:16px; text-align:center; border:1px solid #e2e8f0; }')
[void]$L.Add('.dept-card .dept-name { font-size:12px; font-weight:600; color:#718096; text-transform:uppercase; letter-spacing:.5px; margin-bottom:8px; }')
[void]$L.Add('.dept-card .dept-pct-big { font-size:24px; font-weight:700; color:#2d3748; }')
[void]$L.Add('.dept-card .dept-hours-small { font-size:12px; color:#a0aec0; margin-top:2px; }')
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
[void]$L.Add('.artist-stat { font-size:12px; color:#718096; font-weight:400; }')
[void]$L.Add('@media(max-width:900px){ .dept-grid{ grid-template-columns:repeat(3,1fr); } }')
[void]$L.Add('@media(max-width:600px){ .dept-grid{ grid-template-columns:repeat(2,1fr); } .dist-label{ width:130px; } }')
[void]$L.Add('</style>')
[void]$L.Add('</head>')
[void]$L.Add('<body><div class="container">')

# Header
[void]$L.Add('<div class="header">')
[void]$L.Add('  <h1>ART Department &#8212; &#1054;&#1090;&#1095;&#1105;&#1090; &#1087;&#1086; &#1079;&#1072;&#1076;&#1072;&#1095;&#1072;&#1084;</h1>')
[void]$L.Add('  <div class="meta">&#1055;&#1077;&#1088;&#1080;&#1086;&#1076;: ' + $StartDisp + ' &#8212; ' + $EndDisp + ' &nbsp;|&nbsp; &#1055;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1100;: ART Portfolio &nbsp;|&nbsp; &#1048;&#1089;&#1090;&#1086;&#1095;&#1085;&#1080;&#1082;: Asana time_tracking_entries</div>')
[void]$L.Add('  <div class="stats">')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalHInt + '</div><div class="stat-lbl">&#1063;&#1072;&#1089;&#1086;&#1074; (' + $Label + ')</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalT + '</div><div class="stat-lbl">&#1047;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalSB + '</div><div class="stat-lbl">&#1042; &#1088;&#1072;&#1073;&#1086;&#1090;&#1077; (ART Ready/Test)</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalP + '</div><div class="stat-lbl">&#1055;&#1088;&#1086;&#1077;&#1082;&#1090;&#1086;&#1074;</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalD + '</div><div class="stat-lbl">&#1053;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1081; ART</div></div>')
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Notice
[void]$L.Add('<div class="notice-g">&#9989; <strong>&#1044;&#1072;&#1085;&#1085;&#1099;&#1077; &#1086;&#1090;&#1092;&#1080;&#1083;&#1100;&#1090;&#1088;&#1086;&#1074;&#1072;&#1085;&#1099; &#1095;&#1077;&#1088;&#1077;&#1079; Asana time_tracking_entries API.</strong> &#1060;&#1080;&#1083;&#1100;&#1090;&#1088; &#1087;&#1086; <em>entered_on</em>: ' + $StartDisp + ' &#8212; ' + $EndDisp + '.</div>')

# Dept grid
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title" id="directions"><a href="#directions">&#1056;&#1072;&#1079;&#1073;&#1080;&#1074;&#1082;&#1072; &#1087;&#1086; &#1085;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1103;&#1084; ART</a></div>')
[void]$L.Add('  <div class="dept-grid">')
foreach ($dir in $deptOrder) {
    $dh   = if ($byDirection.ContainsKey($dir)) { $byDirection[$dir] } else { 0.0 }
    $dpct = [math]::Round($dh / $totalH * 100, 1)
    $dhd  = Fmt $dh
    [void]$L.Add('    <div class="dept-card"><div class="dept-name">' + (Esc $dir) + '</div><div class="dept-pct-big">' + $dpct + '%</div><div class="dept-hours-small">' + $dhd + ' &#1095; &#1086;&#1090; &#1086;&#1073;&#1097;&#1077;&#1075;&#1086;</div></div>')
}
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Projects (merged: was 3 separate sections - distribution chart + summary table + project-details -
# combined 14.08.2026 at Roman's request into one expandable list. Each row carries the old
# summary-table's columns (rank, direction pills, task count, hours, %) plus the old dist-chart's
# colored/labeled progress bar (width = % share, matching the old bar-width formula exactly), and
# expands to the old project-details task table instead of living in a separate section.
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title" id="summary"><a href="#summary">&#1057;&#1074;&#1086;&#1076;&#1085;&#1072;&#1103; &#1090;&#1072;&#1073;&#1083;&#1080;&#1094;&#1072; &#1087;&#1086; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1072;&#1084;</a></div>')
$ri = 0; $sumT = 0; $sumH = 0.0; $ci = 0
foreach ($kv in $sortedProj) {
    $ri++
    $ph     = $kv.Value.hours
    $ptasks = $kv.Value.tasks.Count
    $sumT  += $ptasks
    $sumH  += $ph
    $ppct   = [math]::Round($ph / $totalH * 100, 1)
    $barW   = [math]::Round($ph / $maxH * 100)
    $phd    = Fmt $ph
    $col    = $barColors[$ci % $barColors.Count]
    $ci++
    $rankBadge = switch ($ri) {
        1 { '<span class="badge rank-1">1</span>' }
        2 { '<span class="badge rank-2">2</span>' }
        3 { '<span class="badge rank-3">3</span>' }
        default { "$ri" }
    }
    $pillsHtml = ($kv.Value.dirs.Keys | ForEach-Object { Art-Pill $_ }) -join ' '

    [void]$L.Add('  <details class="proj-row">')
    [void]$L.Add('    <summary>')
    [void]$L.Add('      <span class="proj-row-rank">' + $rankBadge + '</span>')
    [void]$L.Add('      <span class="proj-row-name"><strong>' + (Esc $kv.Key) + '</strong><span class="art-types">' + $pillsHtml + '</span></span>')
    [void]$L.Add('      <span class="proj-row-tasks">' + $ptasks + ' &#1079;&#1072;&#1076;.</span>')
    [void]$L.Add('      <span class="proj-row-bar-wrap"><span class="proj-row-bar" style="display:flex;width:' + $barW + '%;background:' + $col + ';">' + $ppct + '%</span></span>')
    [void]$L.Add('      <span class="proj-row-hours">' + $phd + ' &#1095;</span>')
    [void]$L.Add('    </summary>')
    [void]$L.Add('    <div class="detail-content">')

    # Second grouping level: this project's tasks split by ART direction, sorted by each
    # direction's share of the project's hours (desc) - Roman's request 03.09.2026. Each
    # direction group expands to its own task list (Art-Pill already identifies the direction,
    # so the per-task direction column from the old flat table is dropped as redundant here).
    $dirGroups = [ordered]@{}
    foreach ($tk in $kv.Value.tasks) {
        if (-not $dirGroups.Contains($tk.dir)) {
            $dirGroups[$tk.dir] = @{ tasks = [System.Collections.Generic.List[object]]::new(); hours = 0.0 }
        }
        $dirGroups[$tk.dir].tasks.Add($tk)
        $dirGroups[$tk.dir].hours += $tk.hours
    }
    $sortedDirGroups = $dirGroups.GetEnumerator() | Sort-Object { $_.Value.hours } -Descending

    [void]$L.Add('      <div class="proj-dir-groups">')
    foreach ($dg in $sortedDirGroups) {
        $dgHours  = $dg.Value.hours
        $dgPct    = if ($ph -gt 0) { [math]::Round($dgHours / $ph * 100, 1) } else { 0 }
        $dgTasks  = $dg.Value.tasks.Count
        $dgHoursD = Fmt $dgHours
        [void]$L.Add('        <details>')
        [void]$L.Add('          <summary>' + (Art-Pill $dg.Key) + '&nbsp;&nbsp;<span class="artist-stat">' + $dgHoursD + ' &#1095; &mdash; ' + $dgPct + '% &#1086;&#1090; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1072; &mdash; ' + $dgTasks + ' &#1079;&#1072;&#1076;&#1072;&#1095;</span></summary>')
        [void]$L.Add('          <div class="detail-content"><table class="detail-table">')
        [void]$L.Add('            <thead><tr><th>&#1047;&#1072;&#1076;&#1072;&#1095;&#1072;</th><th>&#1048;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1100;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th></tr></thead>')
        [void]$L.Add('            <tbody>')
        foreach ($tk in ($dg.Value.tasks | Sort-Object { $_.hours } -Descending)) {
            $hCell = if ($tk.is_status_based) { '&mdash;' } else { Fmt $tk.hours }
            $trCls = if ($tk.is_status_based) { ' class="status-row"' } else { '' }
            $sPill = if ($tk.is_status_based) { Status-Pill $tk.status_name } else { '' }
            [void]$L.Add('              <tr' + $trCls + '><td><a class="task-link" href="' + $tk.url + '" target="_blank">' + (Esc $tk.name) + '</a>' + $sPill + '</td><td>' + (Esc $tk.assignee) + '</td><td class="hours">' + $hCell + '</td></tr>')
        }
        [void]$L.Add('            <tr class="total-row"><td colspan="2">&#1048;&#1090;&#1086;&#1075;&#1086;: ' + (Art-Pill $dg.Key) + '</td><td>' + $dgHoursD + '</td></tr>')
        [void]$L.Add('            </tbody></table></div>')
        [void]$L.Add('        </details>')
    }
    [void]$L.Add('      </div>')
    [void]$L.Add('      <div class="proj-dir-total">&#1048;&#1090;&#1086;&#1075;&#1086;: ' + (Esc $kv.Key) + ' &mdash; ' + $phd + ' &#1095;</div>')
    [void]$L.Add('    </div>')
    [void]$L.Add('  </details>')
}
[void]$L.Add('  <div class="proj-row-summary-line">&#1048;&#1058;&#1054;&#1043;&#1054;: ' + @($sortedProj).Count + ' &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1086;&#1074; &mdash; ' + $sumT + ' &#1079;&#1072;&#1076;&#1072;&#1095; &mdash; ' + (Fmt $sumH) + ' &#1095; &mdash; 100%</div>')
[void]$L.Add('</div>')

# Employees section (Art Team)
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title" id="employees"><a href="#employees">&#1056;&#1072;&#1089;&#1087;&#1088;&#1077;&#1076;&#1077;&#1083;&#1077;&#1085;&#1080;&#1077; &#1088;&#1072;&#1073;&#1086;&#1090; &#1087;&#1086; &#1089;&#1086;&#1090;&#1088;&#1091;&#1076;&#1085;&#1080;&#1082;&#1072;&#1084;</a></div>')
[void]$L.Add('  <div style="font-size:12px;color:#718096;margin-bottom:12px;">&#1048;&#1089;&#1090;&#1086;&#1095;&#1085;&#1080;&#1082; &#1089;&#1087;&#1080;&#1089;&#1082;&#1072; &#1089;&#1086;&#1090;&#1088;&#1091;&#1076;&#1085;&#1080;&#1082;&#1086;&#1074; &#8212; &#1082;&#1086;&#1084;&#1072;&#1085;&#1076;&#1072; Art Team. &#1055;&#1086;&#1082;&#1072;&#1079;&#1072;&#1085;&#1099; &#1090;&#1086;&#1083;&#1100;&#1082;&#1086; &#1079;&#1072;&#1076;&#1072;&#1095;&#1080; &#1089; &#1079;&#1072;&#1083;&#1086;&#1075;&#1080;&#1088;&#1086;&#1074;&#1072;&#1085;&#1085;&#1099;&#1084; &#1074;&#1088;&#1077;&#1084;&#1077;&#1085;&#1077;&#1084; &#1074; &#1087;&#1077;&#1088;&#1080;&#1086;&#1076;&#1077; (&#1073;&#1077;&#1079; ART Ready/Test-&#1079;&#1072;&#1103;&#1074;&#1086;&#1082; &#1073;&#1077;&#1079; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1072;). &#1047;&#1072;&#1076;&#1072;&#1095;&#1080; &#1074;&#1085;&#1077; ART-&#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1103; &#1087;&#1086;&#1082;&#1072;&#1079;&#1072;&#1085;&#1099; &#1086;&#1090;&#1076;&#1077;&#1083;&#1100;&#1085;&#1099;&#1084; &#1073;&#1083;&#1086;&#1082;&#1086;&#1084; &#1074;&#1085;&#1091;&#1090;&#1088;&#1080; &#1082;&#1072;&#1088;&#1090;&#1086;&#1095;&#1082;&#1080; &#1089;&#1086;&#1090;&#1088;&#1091;&#1076;&#1085;&#1080;&#1082;&#1072;, &#1085;&#1077; &#1074;&#1093;&#1086;&#1076;&#1103;&#1090; &#1074; &#1075;&#1086;&#1083;&#1086;&#1074;&#1085;&#1086;&#1077; &#1095;&#1080;&#1089;&#1083;&#1086; &#1079;&#1072;&#1076;&#1072;&#1095;.</div>')
foreach ($kv in $sortedAssignees) {
    if ($kv.Key -eq 'Unassigned') { continue }
    $ah     = $kv.Value.hours
    if ($ah -le 0) { continue }  # Roman's request 03.09.2026: hide employees with 0 logged hours

    # Split into three groups (found live 03.09.2026, two fixes at once):
    # 1) trackedTasks: portfolio + real hours logged in period - this is the ONLY group counted
    #    in the headline number, so it's provably identical to what "Сравнение" shows for the
    #    same person/period (same filter, same underlying $kv.Value.tasks records).
    # 2) externalTasks: outside the 15-project portfolio but still real tracked hours in period -
    #    kept visible (this is genuine tracked work, e.g. overtime) but shown in its own
    #    clearly-separated sub-list so it never gets silently folded into the headline count.
    # 3) status-based (ART Ready/Test, 0h) tasks - dropped from this table entirely. These are
    #    NOT filtered by the report's period at all (added purely by *current* status, whenever
    #    the script runs) - a completed-in-June, ART-Ready-status task with zero August hours was
    #    exactly what made an "August report" show April/May-old items. Removing them here fixes
    #    both the headline-count mismatch AND the stale-month confusion in one move.
    $trackedTasks  = @($kv.Value.tasks | Where-Object { -not [bool]$_.external -and -not [bool]$_.is_status_based })
    $externalTasks = @($kv.Value.tasks | Where-Object { [bool]$_.external -and -not [bool]$_.is_status_based })
    $trackedCount  = $trackedTasks.Count

    $apct   = if ($empTotalH -gt 0) { [math]::Round($ah / $empTotalH * 100, 1) } else { 0 }
    $ahd    = Fmt $ah
    [void]$L.Add('  <details>')
    [void]$L.Add('    <summary>' + (Esc $kv.Key) + '&nbsp;&nbsp;<span class="artist-stat">' + $ahd + ' &#1095; &mdash; ' + $apct + '% &mdash; ' + $trackedCount + ' &#1079;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</span></summary>')
    [void]$L.Add('    <div class="detail-content"><table class="detail-table">')
    [void]$L.Add('      <thead><tr><th>&#1047;&#1072;&#1076;&#1072;&#1095;&#1072;</th><th>&#1053;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1077;</th><th>&#1055;&#1088;&#1086;&#1077;&#1082;&#1090;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th><th>%</th></tr></thead>')
    [void]$L.Add('      <tbody>')
    foreach ($tk in ($trackedTasks | Sort-Object { $_.hours } -Descending)) {
        $tpct = [math]::Round($tk.hours / $ah * 100, 1)
        [void]$L.Add('        <tr><td><a class="task-link" href="' + $tk.url + '" target="_blank">' + (Esc $tk.name) + '</a></td><td>' + (Art-Pill $tk.dir) + '</td><td>' + (Esc $tk.proj) + '</td><td class="hours">' + (Fmt $tk.hours) + '</td><td class="pct">' + $tpct + '%</td></tr>')
    }
    [void]$L.Add('        <tr class="total-row"><td colspan="3">&#1048;&#1090;&#1086;&#1075;&#1086;: ' + (Esc $kv.Key) + '</td><td>' + $ahd + '</td><td>100%</td></tr>')
    [void]$L.Add('      </tbody></table></div>')
    if ($externalTasks.Count -gt 0) {
        $extH = 0.0
        foreach ($etk in $externalTasks) { $extH += $etk.hours }
        [void]$L.Add('    <details style="margin:8px 0 0 14px;">')
        [void]$L.Add('      <summary style="font-size:12px;">&#1042;&#1085;&#1077; ART-&#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1103; (&#1076;&#1086;&#1087;., &#1085;&#1077; &#1074;&#1093;&#1086;&#1076;&#1080;&#1090; &#1074; &#1089;&#1095;&#1105;&#1090;&#1095;&#1080;&#1082; &#1074;&#1099;&#1096;&#1077;)&nbsp;&nbsp;<span class="artist-stat">' + (Fmt $extH) + ' &#1095; &mdash; ' + $externalTasks.Count + ' &#1079;&#1072;&#1076;&#1072;&#1095;</span></summary>')
        [void]$L.Add('      <div class="detail-content"><table class="detail-table">')
        [void]$L.Add('        <thead><tr><th>&#1047;&#1072;&#1076;&#1072;&#1095;&#1072;</th><th>&#1053;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1077;</th><th>&#1055;&#1088;&#1086;&#1077;&#1082;&#1090;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th></tr></thead>')
        [void]$L.Add('        <tbody>')
        foreach ($tk in ($externalTasks | Sort-Object { $_.hours } -Descending)) {
            [void]$L.Add('          <tr><td><a class="task-link" href="' + $tk.url + '" target="_blank">' + (Esc $tk.name) + '</a></td><td>' + (Art-Pill $tk.dir) + '</td><td>' + (Esc $tk.proj) + '</td><td class="hours">' + (Fmt $tk.hours) + '</td></tr>')
        }
        [void]$L.Add('        </tbody></table></div>')
        [void]$L.Add('    </details>')
    }
    [void]$L.Add('  </details>')
}
# Team members with no tracked time in period
if ($teamMembers -and $teamMembers.Count -gt 0) {
    $inactive = @($teamMembers.Values | Where-Object { -not $byAssignee.ContainsKey($_) } | Sort-Object)
    if ($inactive.Count -gt 0) {
        [void]$L.Add('  <div style="margin-top:14px;font-size:12px;color:#718096;">&#1041;&#1077;&#1079; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1072; &#1074; &#1087;&#1077;&#1088;&#1080;&#1086;&#1076;&#1077;:</div>')
        [void]$L.Add('  <div style="display:flex;flex-wrap:wrap;gap:4px;margin-top:6px;">')
        foreach ($nm in $inactive) {
            [void]$L.Add('    <span style="background:#edf2f7;color:#718096;padding:2px 10px;border-radius:10px;font-size:12px;">' + (Esc $nm) + '</span>')
        }
        [void]$L.Add('  </div>')
    }
}
[void]$L.Add('</div>')

# ============================================================
# Monthly task-count history (Apr 2026 -> current period), team-wide and per employee.
# Computed once here (moved up 03.09.2026 from the old standalone TREND SECTION further below)
# so the per-employee comparison sparklines (added 03.09.2026) and the team-wide trend chart
# read the same numbers from a single pass over each month's time_data_<YYYY-MM>.json, instead
# of two separate file-read loops applying the same filter twice.
# ============================================================
$ruMonths = @('&#1071;&#1085;&#1074;&#1072;&#1088;&#1100;','&#1060;&#1077;&#1074;&#1088;&#1072;&#1083;&#1100;','&#1052;&#1072;&#1088;&#1090;','&#1040;&#1087;&#1088;&#1077;&#1083;&#1100;','&#1052;&#1072;&#1081;','&#1048;&#1102;&#1085;&#1100;',
              '&#1048;&#1102;&#1083;&#1100;','&#1040;&#1074;&#1075;&#1091;&#1089;&#1090;','&#1057;&#1077;&#1085;&#1090;&#1103;&#1073;&#1088;&#1100;','&#1054;&#1082;&#1090;&#1103;&#1073;&#1088;&#1100;','&#1053;&#1086;&#1103;&#1073;&#1088;&#1100;','&#1044;&#1077;&#1082;&#1072;&#1073;&#1088;&#1100;')
$trendStart    = [datetime]::new(2026,4,1)
$curPeriodDate = [datetime]::ParseExact($Start,'yyyy-MM-dd',$null)
$monthlyHistory = [System.Collections.Generic.List[object]]::new()
$md = $trendStart
while ($md -le $curPeriodDate) {
    $mk = $md.ToString('yyyy-MM')
    $mf = "$BASE\time_data_$mk.json"
    if (Test-Path $mf) {
        $mdata = Get-Content $mf -Raw -Encoding utf8 | ConvertFrom-Json
        $byA = @{}
        $cnt = 0
        foreach ($mprop in $mdata.PSObject.Properties) {
            $tv = $mprop.Value
            if ($EXCLUDED_ASSIGNEES -contains [string]$tv.assignee) { continue }
            $isSBv = if ($tv.PSObject.Properties['is_status_based']) { [bool]$tv.is_status_based } else { $false }
            if (-not [bool]$tv.external -and -not $isSBv) {
                $cnt++
                $whoV = [string]$tv.assignee
                if ($whoV -ne 'Unassigned') {
                    if (-not $byA.ContainsKey($whoV)) { $byA[$whoV] = 0 }
                    $byA[$whoV]++
                }
            }
        }
        $monthlyHistory.Add(@{ Label = $ruMonths[$md.Month-1]; Total = $cnt; ByAssignee = $byA })
    }
    $md = $md.AddMonths(1)
}

# ============================================================
# COMPARISON SECTION (vs previous month)
# ============================================================
$prevData2 = $null; $prevPeriodLbl = $null
try {
    $pd0 = [datetime]::ParseExact($Start, 'yyyy-MM-dd', $null).AddMonths(-1)
    $prevKey0 = $pd0.ToString('yyyy-MM')
    $prevJson0 = "$BASE\time_data_$prevKey0.json"
    if (Test-Path $prevJson0) {
        $prevData2 = Get-Content $prevJson0 -Raw -Encoding utf8 | ConvertFrom-Json
        $mn0 = @('January','February','March','April','May','June','July','August','September','October','November','December')
        $prevPeriodLbl = "$($mn0[$pd0.Month-1]) $($pd0.Year)"
    }
} catch {}

if ($prevData2 -and $prevPeriodLbl) {
    function DSN([double]$v) { if ($v -ge 0) { '+' } else { '' } }
    function DCol([double]$v,[bool]$inv=$false) {
        $pos = if ($inv) { $v -le 0 } else { $v -ge 0 }
        if ($pos) { '#38a169' } else { '#e53e3e' }
    }

    # Build per-person stats for prev month (skip Unassigned). Scoped to "tasks with tracking"
    # (excludes external + status-based 0h tasks) - matches the site-wide trend/header stat and,
    # since 03.09.2026, the per-employee sparkline embedded in this same row below. Before
    # 03.09.2026 this reused $byAssignee (all assigned tasks incl. 0h status-based) which made a
    # row's own header numbers disagree with its own expanded chart - found live by Roman
    # comparing "Разбивка по сотрудникам" (9 tasks) against this row's sparkline (8 tasks) for
    # the same person/period. "Разбивка по сотрудникам" intentionally keeps the broader
    # definition (it's meant to show full workload incl. not-yet-tracked ART Ready/Test items) -
    # only this comparison table + its sparkline are realigned here.
    $prevPP = @{}
    foreach ($prop0 in $prevData2.PSObject.Properties) {
        $t0 = $prop0.Value; $who0 = [string]$t0.assignee
        if ($who0 -eq 'Unassigned' -or $EXCLUDED_ASSIGNEES -contains $who0) { continue }
        $isSBv0 = if ($t0.PSObject.Properties['is_status_based']) { [bool]$t0.is_status_based } else { $false }
        if ([bool]$t0.external -or $isSBv0) { continue }
        if (-not $prevPP[$who0]) { $prevPP[$who0] = @{tasks=0;hours=0.0} }
        $prevPP[$who0].tasks++
        $prevPP[$who0].hours += [double]$t0.hours
    }

    # Build per-person stats for current month - same "tracking only" scope as $prevPP above,
    # built from $tasks2 directly (not $byAssignee, which is unscoped) for the same reason.
    $currPP = @{}
    foreach ($gid0 in $tasks2.Keys) {
        $t0 = $tasks2[$gid0]; $who0 = [string]$t0.assignee
        if ($who0 -eq 'Unassigned' -or $EXCLUDED_ASSIGNEES -contains $who0) { continue }
        if ([bool]$t0.external -or [bool]$t0.is_status_based) { continue }
        if (-not $currPP.ContainsKey($who0)) { $currPP[$who0] = @{tasks=0;hours=0.0} }
        $currPP[$who0].tasks++
        $currPP[$who0].hours += [double]$t0.hours
    }

    $joined0 = @($currPP.Keys | Where-Object { -not $prevPP.ContainsKey($_) } | Sort-Object)
    $left0   = @($prevPP.Keys | Where-Object { -not $currPP.ContainsKey($_) } | Sort-Object)

    [void]$L.Add('<div class="card">')
    [void]$L.Add('  <div class="section-title" id="comparison"><a href="#comparison">&#1057;&#1088;&#1072;&#1074;&#1085;&#1077;&#1085;&#1080;&#1077; &#1089; ' + (Esc $prevPeriodLbl) + '</a></div>')

    # Joined / Left chips
    if ($joined0.Count -gt 0 -or $left0.Count -gt 0) {
        [void]$L.Add('  <div style="display:flex;gap:16px;margin-bottom:20px;flex-wrap:wrap;">')
        if ($joined0.Count -gt 0) {
            [void]$L.Add('    <div style="flex:1;min-width:220px;">')
            [void]$L.Add('      <div style="font-size:12px;font-weight:600;color:#276749;margin-bottom:6px;">+ &#1042;&#1087;&#1077;&#1088;&#1074;&#1099;&#1077; &#1074; ' + (Esc $Label) + ':</div>')
            [void]$L.Add('      <div style="display:flex;flex-wrap:wrap;gap:4px;">')
            foreach ($nm0 in $joined0) { [void]$L.Add('        <span style="background:#c6f6d5;color:#276749;padding:2px 10px;border-radius:10px;font-size:12px;">' + (Esc $nm0) + '</span>') }
            [void]$L.Add('      </div></div>')
        }
        if ($left0.Count -gt 0) {
            [void]$L.Add('    <div style="flex:1;min-width:220px;">')
            [void]$L.Add('      <div style="font-size:12px;font-weight:600;color:#c53030;margin-bottom:6px;">&#8722; &#1053;&#1077; &#1072;&#1082;&#1090;&#1080;&#1074;&#1085;&#1099; &#1074; ' + (Esc $Label) + ':</div>')
            [void]$L.Add('      <div style="display:flex;flex-wrap:wrap;gap:4px;">')
            foreach ($nm0 in $left0) { [void]$L.Add('        <span style="background:#fed7d7;color:#c53030;padding:2px 10px;border-radius:10px;font-size:12px;">' + (Esc $nm0) + '</span>') }
            [void]$L.Add('      </div></div>')
        }
        [void]$L.Add('  </div>')
    }

    # Per-employee comparison list. Was a plain <table>; converted to expandable <details> rows
    # 03.09.2026 so each employee can be opened to a sparkline of their own tracked-task count by
    # month (same source/filter as the team-wide trend chart further down, scoped to this person).
    [void]$L.Add('  <div class="cmp-header">')
    [void]$L.Add('    <span class="cmp-col cmp-name">&#1057;&#1086;&#1090;&#1088;&#1091;&#1076;&#1085;&#1080;&#1082;</span>')
    [void]$L.Add('    <span class="cmp-col">' + (Esc $prevPeriodLbl) + '<br><small>&#1095; / &#1079;&#1072;&#1076;.</small></span>')
    [void]$L.Add('    <span class="cmp-col">' + (Esc $Label) + '<br><small>&#1095; / &#1079;&#1072;&#1076;.</small></span>')
    [void]$L.Add('    <span class="cmp-col">&#916; &#1063;&#1072;&#1089;&#1086;&#1074;</span>')
    [void]$L.Add('    <span class="cmp-col">&#916; &#1047;&#1072;&#1076;&#1072;&#1095;</span>')
    [void]$L.Add('    <span class="cmp-col">&#1063;&#1072;&#1089;/&#1079;&#1072;&#1076;. (&#1101;&#1092;&#1092;.)</span>')
    [void]$L.Add('  </div>')

    $allP0 = @{}
    foreach ($n0 in $currPP.Keys) { $allP0[$n0] = 1 }
    foreach ($n0 in $prevPP.Keys) { $allP0[$n0] = 1 }
    $sortedP0 = $allP0.Keys | Sort-Object { if ($currPP[$_]) { -$currPP[$_].hours } else { 9999 } }

    foreach ($nm0 in $sortedP0) {
        $cH0  = if ($currPP[$nm0]) { $currPP[$nm0].hours } else { 0.0 }
        $cT0b = if ($currPP[$nm0]) { $currPP[$nm0].tasks } else { 0 }
        $pH0  = if ($prevPP[$nm0]) { $prevPP[$nm0].hours } else { 0.0 }
        $pT0  = if ($prevPP[$nm0]) { $prevPP[$nm0].tasks } else { 0 }

        $cEff0 = if ($cT0b -gt 0) { [math]::Round($cH0/$cT0b,1) } else { 0.0 }
        $pEff0 = if ($pT0 -gt 0)  { [math]::Round($pH0/$pT0,1) }  else { 0.0 }
        $dEff0 = if ($cEff0 -gt 0 -and $pEff0 -gt 0) { [math]::Round($cEff0-$pEff0,1) } else { 0.0 }

        $dHv0  = $cH0 - $pH0
        $dHvp0 = if ($pH0 -gt 0) { [math]::Round($dHv0/$pH0*100,1) } else { 0 }
        $dTv0  = $cT0b - $pT0
        $dTvp0 = if ($pT0 -gt 0) { [math]::Round($dTv0/$pT0*100,1) } else { 0 }

        $prevC0 = if ($pT0 -gt 0)  { (Fmt $pH0) + ' / ' + $pT0  } else { '&mdash;' }
        $currC0 = if ($cT0b -gt 0) { (Fmt $cH0) + ' / ' + $cT0b } else { '&mdash;' }

        $effC0 = if ($pEff0 -gt 0 -and $cEff0 -gt 0) {
            $es = DSN $dEff0; $ec = DCol $dEff0 $true
            [string]$pEff0 + ' &#8594; <strong style="color:' + $ec + '">' + [string]$cEff0 + '</strong> <small style="color:#a0aec0">(' + $es + [string]$dEff0 + ')</small>'
        } elseif ($cEff0 -gt 0) { '&#8594; ' + [string]$cEff0 }
        else { '&mdash;' }

        $dHhtml0 = if ($pH0 -gt 0) {
            $s0 = DSN $dHv0; $c0 = DCol $dHv0
            '<span style="color:' + $c0 + ';font-weight:600">' + $s0 + (Fmt $dHv0) + '</span><br><small style="color:#a0aec0">' + $s0 + $dHvp0 + '%</small>'
        } else { '<small style="color:#a0aec0">&#1085;&#1086;&#1074;&#1099;&#1081;</small>' }

        $dThtml0 = if ($pT0 -gt 0) {
            $s0 = DSN $dTv0; $c0 = DCol $dTv0
            '<span style="color:' + $c0 + ';font-weight:600">' + $s0 + $dTv0 + '</span><br><small style="color:#a0aec0">' + $s0 + $dTvp0 + '%</small>'
        } else { '<small style="color:#a0aec0">&#1085;&#1086;&#1074;&#1099;&#1081;</small>' }

        $empPoints = @($monthlyHistory | ForEach-Object {
            $v = if ($_.ByAssignee.ContainsKey($nm0)) { $_.ByAssignee[$nm0] } else { 0 }
            @{ Label = $_.Label; Value = $v }
        })
        $hasAnyTasks = ($empPoints | Where-Object { $_.Value -gt 0 } | Measure-Object).Count -gt 0

        [void]$L.Add('    <details class="cmp-row">')
        [void]$L.Add('      <summary>')
        [void]$L.Add('        <span class="cmp-col cmp-name"><strong>' + (Esc $nm0) + '</strong></span>')
        [void]$L.Add('        <span class="cmp-col" style="color:#718096;">' + $prevC0 + '</span>')
        [void]$L.Add('        <span class="cmp-col" style="font-weight:700;">' + $currC0 + '</span>')
        [void]$L.Add('        <span class="cmp-col">' + $dHhtml0 + '</span>')
        [void]$L.Add('        <span class="cmp-col">' + $dThtml0 + '</span>')
        [void]$L.Add('        <span class="cmp-col" style="font-size:13px;">' + $effC0 + '</span>')
        [void]$L.Add('      </summary>')
        [void]$L.Add('      <div class="detail-content" style="padding:14px;">')
        if ($hasAnyTasks) {
            [void]$L.Add('        <div style="font-size:12px;color:#718096;margin-bottom:6px;">&#1047;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084; &#1087;&#1086; &#1084;&#1077;&#1089;&#1103;&#1094;&#1072;&#1084; &mdash; ' + (Esc $nm0) + '</div>')
            [void]$L.Add('        ' + (Build-TrendSvg $empPoints))
        } else {
            [void]$L.Add('        <div style="font-size:13px;color:#a0aec0;">&#1053;&#1077;&#1076;&#1086;&#1089;&#1090;&#1072;&#1090;&#1086;&#1095;&#1085;&#1086; &#1076;&#1072;&#1085;&#1085;&#1099;&#1093; &#1076;&#1083;&#1103; &#1075;&#1088;&#1072;&#1092;&#1080;&#1082;&#1072;.</div>')
        }
        [void]$L.Add('      </div>')
        [void]$L.Add('    </details>')
    }
    [void]$L.Add('</div>')
}

# ============================================================
# TREND SECTION (tasks with tracking, April 2026 -> current period)
# ============================================================
$trendPoints = @($monthlyHistory | ForEach-Object { @{ Label = $_.Label; Value = $_.Total } })

if ($trendPoints.Count -ge 2) {
    [void]$L.Add('<div class="card">')
    [void]$L.Add('  <div class="section-title" id="trend"><a href="#trend">&#1044;&#1080;&#1085;&#1072;&#1084;&#1080;&#1082;&#1072; &#1087;&#1086; &#1084;&#1077;&#1089;&#1103;&#1094;&#1072;&#1084; &#8212; &#1079;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</a></div>')
    [void]$L.Add('  ' + (Build-TrendSvg $trendPoints))
    [void]$L.Add('  <div style="color:#a0aec0;font-size:12px;margin-top:8px;">&#1052;&#1077;&#1090;&#1088;&#1080;&#1082;&#1072; &#8212; &#1090;&#1072; &#1078;&#1077;, &#1095;&#1090;&#1086; &#1074; &#1096;&#1072;&#1087;&#1082;&#1077; &#1082;&#1072;&#1078;&#1076;&#1086;&#1075;&#1086; &#1084;&#1077;&#1089;&#1103;&#1095;&#1085;&#1086;&#1075;&#1086; &#1086;&#1090;&#1095;&#1105;&#1090;&#1072; (&laquo;&#1047;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;&raquo;): &#1087;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1100;&#1085;&#1099;&#1077; &#1079;&#1072;&#1076;&#1072;&#1095;&#1080; ART &#1089; &#1092;&#1072;&#1082;&#1090;&#1080;&#1095;&#1077;&#1089;&#1082;&#1080; &#1079;&#1072;&#1083;&#1086;&#1075;&#1080;&#1088;&#1086;&#1074;&#1072;&#1085;&#1085;&#1099;&#1084; &#1074;&#1088;&#1077;&#1084;&#1077;&#1085;&#1077;&#1084; &#1074; &#1087;&#1077;&#1088;&#1080;&#1086;&#1076;&#1077;.</div>')
    [void]$L.Add('</div>')
}

# ============================================================
# CAS vs GAME-PROJECT (ART backlog) SECTION
# ============================================================
if ($rawProjStats -and $rawProjStats.Count -gt 0) {
    $grandTotal  = $casTotalCount + $backlogTotalCount
    $grandHours  = $casHoursTotal + $backlogHoursTotal
    $casTotalPct = if ($grandTotal -gt 0) { [math]::Round($casTotalCount / $grandTotal * 100, 1) } else { 0 }
    $bkTotalPct  = if ($grandTotal -gt 0) { [math]::Round($backlogTotalCount / $grandTotal * 100, 1) } else { 0 }
    $casHoursPct = if ($grandHours -gt 0) { [math]::Round($casHoursTotal / $grandHours * 100, 1) } else { 0 }
    $bkHoursPct  = if ($grandHours -gt 0) { [math]::Round($backlogHoursTotal / $grandHours * 100, 1) } else { 0 }

    [void]$L.Add('<details id="cas-vs-game">')
    [void]$L.Add('  <summary><a href="#cas-vs-game" style="color:inherit;text-decoration:none;">CAS vs &#1080;&#1075;&#1088;&#1086;&#1074;&#1099;&#1077; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1099; ART</a>&nbsp;&nbsp;<span style="color:#718096;font-weight:400">' + $grandTotal + ' &#1079;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</span></summary>')
    [void]$L.Add('  <div class="detail-content" style="padding:16px;background:white;">')
    [void]$L.Add('    <div style="color:#a0aec0;font-size:12px;margin-bottom:14px;">&#1047;&#1072;&#1076;&#1072;&#1095;&#1080; &#1089; &#1092;&#1072;&#1082;&#1090;&#1080;&#1095;&#1077;&#1089;&#1082;&#1080; &#1079;&#1072;&#1083;&#1086;&#1075;&#1080;&#1088;&#1086;&#1074;&#1072;&#1085;&#1085;&#1099;&#1084; &#1074;&#1088;&#1077;&#1084;&#1077;&#1085;&#1077;&#1084; (time_tracking_entries) &#1074;&#1085;&#1091;&#1090;&#1088;&#1080; &#1087;&#1077;&#1088;&#1080;&#1086;&#1076;&#1072; ' + $StartDisp + ' &#8212; ' + $EndDisp + ' &#8212; &#1090;&#1086;&#1090; &#1078;&#1077; &#1082;&#1088;&#1080;&#1090;&#1077;&#1088;&#1080;&#1081;, &#1095;&#1090;&#1086; &#1080; &#171;&#1047;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;&#187; &#1074; &#1096;&#1072;&#1087;&#1082;&#1077; &#1086;&#1090;&#1095;&#1105;&#1090;&#1072; &#1080; &#1085;&#1072; &#1075;&#1088;&#1072;&#1092;&#1080;&#1082;&#1077; &#1076;&#1080;&#1085;&#1072;&#1084;&#1080;&#1082;&#1080;. CAS &mdash; &#1074;&#1085;&#1091;&#1090;&#1088;&#1077;&#1085;&#1085;&#1080;&#1077; &#1079;&#1072;&#1087;&#1088;&#1086;&#1089;&#1099; (&#1084;&#1072;&#1088;&#1082;&#1077;&#1090;&#1080;&#1085;&#1075;/&#1087;&#1088;&#1077;&#1079;&#1077;&#1085;&#1090;&#1072;&#1094;&#1080;&#1080;/&#1089;&#1086;&#1094;&#1089;&#1077;&#1090;&#1080;), &#1085;&#1077; &#1080;&#1075;&#1088;&#1086;&#1074;&#1086;&#1081; &#1072;&#1088;&#1090;-&#1087;&#1088;&#1086;&#1076;&#1072;&#1082;&#1096;&#1085;.</div>')

    [void]$L.Add('    <table class="summary-table"><tr><th>&#1043;&#1088;&#1091;&#1087;&#1087;&#1072;</th><th>&#1047;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</th><th>% &#1079;&#1072;&#1076;&#1072;&#1095;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th><th>% &#1095;&#1072;&#1089;&#1086;&#1074;</th></tr>')
    [void]$L.Add('      <tr><td><strong>CAS (&#1074;&#1085;&#1091;&#1090;&#1088;&#1077;&#1085;&#1085;&#1080;&#1077; &#1079;&#1072;&#1087;&#1088;&#1086;&#1089;&#1099;)</strong></td><td>' + $casTotalCount + '</td><td>' + $casTotalPct + '%</td><td>' + (Fmt $casHoursTotal) + '</td><td>' + $casHoursPct + '%</td></tr>')
    [void]$L.Add('      <tr><td><strong>&#1048;&#1075;&#1088;&#1086;&#1074;&#1099;&#1077; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1099; ART (backlog)</strong></td><td>' + $backlogTotalCount + '</td><td>' + $bkTotalPct + '%</td><td>' + (Fmt $backlogHoursTotal) + '</td><td>' + $bkHoursPct + '%</td></tr>')
    [void]$L.Add('      <tr class="total-row"><td>&#1048;&#1058;&#1054;&#1043;&#1054;</td><td>' + $grandTotal + '</td><td>100%</td><td>' + (Fmt $grandHours) + '</td><td>100%</td></tr>')
    [void]$L.Add('    </table>')

    [void]$L.Add('    <div class="subsection-title" style="font-size:13px;font-weight:700;margin:20px 0 10px;color:#4a5568;text-transform:uppercase;letter-spacing:.4px;">&#1055;&#1086; CAS-&#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1072;&#1084;</div>')
    [void]$L.Add('    <table class="summary-table"><tr><th>&#1055;&#1088;&#1086;&#1077;&#1082;&#1090;</th><th>&#1047;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</th><th>%</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th></tr>')
    foreach ($gid in $CAS_LABELS.Keys) {
        $rs  = $rawProjStats[$gid]; $hrs = $rs.hoursMin / 60.0
        $pct = if ($casTotalCount -gt 0) { [math]::Round($rs.total / $casTotalCount * 100, 1) } else { 0 }
        [void]$L.Add('      <tr><td>' + $rs.name + '</td><td>' + $rs.total + '</td><td>' + $pct + '%</td><td>' + (Fmt $hrs) + '</td></tr>')
    }
    [void]$L.Add('      <tr class="total-row"><td>&#1048;&#1058;&#1054;&#1043;&#1054;</td><td>' + $casTotalCount + '</td><td>100%</td><td>' + (Fmt $casHoursTotal) + '</td></tr>')
    [void]$L.Add('    </table>')

    [void]$L.Add('    <div style="color:#a0aec0;font-size:12px;margin:14px 0 10px;">&#1050;&#1083;&#1080;&#1082; &#1087;&#1086; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1091; &#8212; &#1089;&#1087;&#1080;&#1089;&#1086;&#1082; &#1079;&#1072;&#1076;&#1072;&#1095; &#1080; &#1087;&#1086;&#1076;&#1079;&#1072;&#1076;&#1072;&#1095; (&#8618;) &#1089; &#1079;&#1072;&#1083;&#1086;&#1075;&#1080;&#1088;&#1086;&#1074;&#1072;&#1085;&#1085;&#1099;&#1084; &#1074;&#1088;&#1077;&#1084;&#1077;&#1085;&#1077;&#1084; &#1074; &#1087;&#1077;&#1088;&#1080;&#1086;&#1076;&#1077;.</div>')
    foreach ($gid in $CAS_LABELS.Keys) {
        $rs = $rawProjStats[$gid]
        [void]$L.Add('    <details><summary>' + $rs.name + '&nbsp;&nbsp;<span style="color:#718096;font-weight:400">' + $rs.total + ' &#1079;&#1072;&#1076;&#1072;&#1095; &mdash; ' + (Fmt ($rs.hoursMin/60.0)) + ' &#1095;</span></summary>')
        [void]$L.Add('      <div class="detail-content"><table class="detail-table">')
        [void]$L.Add('        <tr><th>&#1047;&#1072;&#1076;&#1072;&#1095;&#1072;</th><th>&#1047;&#1072;&#1083;&#1086;&#1075;&#1080;&#1088;&#1086;&#1074;&#1072;&#1083;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th></tr>')
        foreach ($tk in ($rs.tasks | Sort-Object { $_.hours } -Descending)) {
            $tUrl    = if ($tk.url) { $tk.url } else { '#' }
            $tName   = if ($tk.isSub) { '&#8618; ' + (Esc $tk.name) } else { (Esc $tk.name) }
            $tLogger = if ($tk.logger) { (Esc $tk.logger) } else { '<span style="color:#a0aec0;">&mdash;</span>' }
            [void]$L.Add('        <tr><td><a class="task-link" href="' + $tUrl + '" target="_blank">' + $tName + '</a></td><td>' + $tLogger + '</td><td class="hours">' + (Fmt $tk.hours) + '</td></tr>')
        }
        if ($rs.tasks.Count -eq 0) {
            [void]$L.Add('        <tr><td colspan="3" style="color:#a0aec0;">&#1053;&#1077;&#1090; &#1079;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084; &#1074; &#1087;&#1077;&#1088;&#1080;&#1086;&#1076;&#1077;.</td></tr>')
        }
        [void]$L.Add('      </table></div>')
        [void]$L.Add('    </details>')
    }

    [void]$L.Add('    <div class="subsection-title" style="font-size:13px;font-weight:700;margin:20px 0 10px;color:#4a5568;text-transform:uppercase;letter-spacing:.4px;">&#1055;&#1086; &#1080;&#1075;&#1088;&#1086;&#1074;&#1099;&#1084; (backlog) &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1072;&#1084; ART</div>')
    [void]$L.Add('    <table class="summary-table"><tr><th>&#1055;&#1088;&#1086;&#1077;&#1082;&#1090;</th><th>&#1047;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</th><th>%</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th></tr>')
    foreach ($gid in $BACKLOG_LABELS.Keys) {
        $rs  = $rawProjStats[$gid]; $hrs = $rs.hoursMin / 60.0
        $pct = if ($backlogTotalCount -gt 0) { [math]::Round($rs.total / $backlogTotalCount * 100, 1) } else { 0 }
        [void]$L.Add('      <tr><td>' + $rs.name + '</td><td>' + $rs.total + '</td><td>' + $pct + '%</td><td>' + (Fmt $hrs) + '</td></tr>')
    }
    [void]$L.Add('      <tr class="total-row"><td>&#1048;&#1058;&#1054;&#1043;&#1054;</td><td>' + $backlogTotalCount + '</td><td>100%</td><td>' + (Fmt $backlogHoursTotal) + '</td></tr>')
    [void]$L.Add('    </table>')
    [void]$L.Add('  </div>')
    [void]$L.Add('</details>')
}

# Footer
$genDate = Get-Date -Format 'dd.MM.yyyy HH:mm'
[void]$L.Add('<div style="text-align:center;color:#a0aec0;font-size:12px;padding:24px 0">&#1057;&#1075;&#1077;&#1085;&#1077;&#1088;&#1080;&#1088;&#1086;&#1074;&#1072;&#1085;&#1086;: ' + $genDate + ' &nbsp;|&nbsp; Asana time_tracking_entries &nbsp;|&nbsp; ' + $StartDisp + ' &#8212; ' + $EndDisp + '</div>')
[void]$L.Add('</div></body></html>')

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($htmlFile, $L, $utf8)
Write-Host "=== DONE ==="
Write-Host "HTML: $htmlFile  ($($L.Count) lines)"
Write-Host "Stats: $totalHInt h / $totalT tasks / $totalP projects"

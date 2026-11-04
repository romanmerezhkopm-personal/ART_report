# Thin test for the shared engine D:\project\guardrails\asana_http.ps1 (Invoke-AsanaGetWithRetry), with the
# failure seen live on 04.11.2026: DNS "The remote name could not be resolved: 'app.asana.com'" mid-run.
# Run:  powershell -File test_asana_http.ps1            (offline + live)
#       powershell -File test_asana_http.ps1 -OfflineOnly
param([switch]$OfflineOnly)
$ErrorActionPreference = "Stop"
. "D:\project\guardrails\asana_http.ps1"

$fail = 0
function Check([string]$name, [bool]$ok) { if ($ok) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name"; $script:fail++ } }
function New-HttpError([object]$status, [string]$msg) { $e = [System.Exception]::new($msg); if ($null -ne $status) { $e.Data['HttpStatus'] = $status }; $e }
# A fetcher that fails with the given errors in order, then returns 'ok'. Counts calls and sleeps.
function New-Script([object[]]$errors) {
    $s = @{ calls = 0; slept = [System.Collections.Generic.List[int]]::new(); errors = $errors }
    $s.fetch = { param($u) $s.calls++; if ($s.calls -le $s.errors.Count) { throw $s.errors[$s.calls - 1] }; 'ok' }.GetNewClosure()
    $s.sleep = { param($sec) $s.slept.Add($sec) }.GetNewClosure()
    $s
}
$dns = 'The remote name could not be resolved: ''app.asana.com'''

# --- must BLOCK (throw, never return partial/empty data) ---------------------------------------
$s = New-Script (@(1..7) | ForEach-Object { New-HttpError $null $dns })
$threw = $false; try { Invoke-AsanaGetWithRetry -Url 'u' -Fetcher $s.fetch -Sleeper $s.sleep | Out-Null } catch { $threw = $_.Exception.Message -like '*after 7 attempts*' }
Check "DNS down for the whole retry window -> throws after 7 attempts" ($threw -and $s.calls -eq 7)
$s = New-Script @((New-HttpError 401 'Not Authorized'))
$threw = $false; try { Invoke-AsanaGetWithRetry -Url 'u' -Fetcher $s.fetch -Sleeper $s.sleep | Out-Null } catch { $threw = $true }
Check "401 throws at once, no retries" ($threw -and $s.calls -eq 1 -and $s.slept.Count -eq 0)
$s = New-Script @((New-HttpError 404 'Unknown object'))
$threw = $false; try { Invoke-AsanaGetWithRetry -Url 'u' -Fetcher $s.fetch -Sleeper $s.sleep | Out-Null } catch { $threw = $true }
Check "404 without -AllowNotFound throws" ($threw -and $s.calls -eq 1)

# --- must PASS -----------------------------------------------------------------------------------
$s = New-Script @((New-HttpError $null $dns), (New-HttpError $null $dns))
$r = Invoke-AsanaGetWithRetry -Url 'u' -Fetcher $s.fetch -Sleeper $s.sleep
Check "DNS blip (2 failures) -> retried, data returned" ($r -eq 'ok' -and $s.calls -eq 3 -and (($s.slept -join ',') -eq '2,5'))
$s = New-Script @((New-HttpError 429 'Too Many Requests'), (New-HttpError 503 'Service Unavailable'))
Check "429 then 503 -> retried, data returned" ((Invoke-AsanaGetWithRetry -Url 'u' -Fetcher $s.fetch -Sleeper $s.sleep) -eq 'ok' -and $s.calls -eq 3)
$s = New-Script @((New-HttpError 404 'Unknown object'))
$r = Invoke-AsanaGetWithRetry -Url 'u' -AllowNotFound -Fetcher $s.fetch -Sleeper $s.sleep
Check "404 with -AllowNotFound -> `$null, no retries (task deleted during the run)" ($null -eq $r -and $s.calls -eq 1)

# --- live: real Invoke-RestMethod errors are classified the same way ------------------------------
if (-not $OfflineOnly) {
    $h = @{ Authorization = "Bearer " + (Get-Content "$PSScriptRoot\asana_pat.txt" -Raw).Trim() }
    $me = Invoke-AsanaGetWithRetry -Url "https://app.asana.com/api/1.0/users/me?opt_fields=name" -RequestHeaders $h
    Check "live: 200 returns data" ([bool]$me.data.name)
    $gone = Invoke-AsanaGetWithRetry -Url "https://app.asana.com/api/1.0/tasks/1200000000000001?opt_fields=name" -RequestHeaders $h -AllowNotFound
    Check "live: real 404 (no such task) -> `$null with -AllowNotFound" ($null -eq $gone)
    $threw = $false
    try { Invoke-AsanaGetWithRetry -Url "https://app.asana.invalid/api/1.0/users/me" -RequestHeaders $h -WaitSeconds @(0, 0) | Out-Null } catch { $threw = $_.Exception.Message -like '*after 3 attempts*no response*' }
    Check "live: unresolvable host (real DNS error) -> retried, then throws" $threw
}
if ($fail) { Write-Host "`n$fail check(s) FAILED"; exit 1 } else { Write-Host "`nAll checks passed"; exit 0 }

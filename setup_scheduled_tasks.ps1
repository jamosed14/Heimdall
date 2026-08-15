# Registers three per-user Windows Scheduled Tasks (no admin rights required) that keep every
# panel's cached data fresh:
#   1. "Heimdall Catallaxy Open Pass"   - weekdays only, 9:35 AM local time
#   2. "Heimdall Catallaxy Close Pass"  - every day (weekdays + weekends), 4:05 PM local time
#   3. "Heimdall Catallaxy Logon Refresh" - runs whenever you log on (catch-up if the PC
#                                        was off/asleep for a scheduled pass)
# All three run refresh_all.ps1, which calls every panel's fetch script in turn - deliberately
# not a smaller weekend-only subset, since the non-crypto sources (FRED/EIA/SEC) are already
# fail-stale-safe no-ops on a day with nothing new to report. Same schedule target as the
# GitHub Actions workflow (see .github/workflows/refresh.yml) - open pass gives the day's
# opening auctions time to settle, close pass does the same for closing prints.
#
# NOTE: Task Scheduler's "Daily/Weekly -At" triggers use whatever timezone this PC's clock is
# set to, not literal ET. If this machine isn't on Eastern time, adjust the -At values below
# accordingly - unlike the GitHub Actions workflow, there's no DST-aware runtime check here
# because Windows daily/weekly triggers already track the PC's local wall clock (including its
# own DST) on their own.
#
# Safe to re-run this setup script any time - it overwrites the existing task definitions
# rather than duplicating them.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $root "refresh_all.ps1"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

# Old single-pass task name from before the open/close split - remove it if present so it
# doesn't linger alongside the new tasks below.
Unregister-ScheduledTask -TaskName "Heimdall Catallaxy Daily Refresh" -Confirm:$false -ErrorAction SilentlyContinue

$openTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "9:35AM"
Register-ScheduledTask -TaskName "Heimdall Catallaxy Open Pass" -Action $action -Trigger $openTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Open Pass (weekdays @ 9:35 AM)"

$closeTrigger = New-ScheduledTaskTrigger -Daily -At "4:05PM"
Register-ScheduledTask -TaskName "Heimdall Catallaxy Close Pass" -Action $action -Trigger $closeTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Close Pass (every day @ 4:05 PM)"

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "Heimdall Catallaxy Logon Refresh" -Action $action -Trigger $logonTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Logon Refresh (at every log on)"

Write-Output ""
Write-Output "Manage these any time via Task Scheduler (taskschd.msc), under Task Scheduler Library."
Write-Output "To remove: Unregister-ScheduledTask -TaskName 'Heimdall Catallaxy Open Pass','Heimdall Catallaxy Close Pass','Heimdall Catallaxy Logon Refresh' -Confirm:`$false"

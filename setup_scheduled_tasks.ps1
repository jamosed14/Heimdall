# Registers four per-user Windows Scheduled Tasks (no admin rights required) that keep every
# panel's cached data fresh:
#   1. "Heimdall Catallaxy Open Pass"   - weekdays only, 9:40 AM local time
#   2. "Heimdall Catallaxy Midday Pass" - weekdays only, 12:30 PM local time
#   3. "Heimdall Catallaxy Close Pass"  - every day (weekdays + weekends), 4:10 PM local time
#   4. "Heimdall Catallaxy Logon Refresh" - runs whenever you log on (catch-up if the PC
#                                        was off/asleep for a scheduled pass)
# All four run refresh_all.ps1, which calls every panel's fetch script in turn - deliberately
# not a smaller weekend-only subset, since the non-crypto sources (FRED/EIA/SEC) are already
# fail-stale-safe no-ops on a day with nothing new to report. Same schedule target as the
# GitHub Actions workflow (see .github/workflows/refresh.yml) - open/close passes give the
# day's opening/closing auctions time to settle, midday is a weekday-only intraday check.
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

# Old task names from before this schedule - remove if present so they don't linger alongside
# the current set below.
Unregister-ScheduledTask -TaskName "Heimdall Catallaxy Daily Refresh" -Confirm:$false -ErrorAction SilentlyContinue

$openTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "9:40AM"
Register-ScheduledTask -TaskName "Heimdall Catallaxy Open Pass" -Action $action -Trigger $openTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Open Pass (weekdays @ 9:40 AM)"

$middayTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "12:30PM"
Register-ScheduledTask -TaskName "Heimdall Catallaxy Midday Pass" -Action $action -Trigger $middayTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Midday Pass (weekdays @ 12:30 PM)"

$closeTrigger = New-ScheduledTaskTrigger -Daily -At "4:10PM"
Register-ScheduledTask -TaskName "Heimdall Catallaxy Close Pass" -Action $action -Trigger $closeTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Close Pass (every day @ 4:10 PM)"

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "Heimdall Catallaxy Logon Refresh" -Action $action -Trigger $logonTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Logon Refresh (at every log on)"

Write-Output ""
Write-Output "Manage these any time via Task Scheduler (taskschd.msc), under Task Scheduler Library."
Write-Output "To remove: Unregister-ScheduledTask -TaskName 'Heimdall Catallaxy Open Pass','Heimdall Catallaxy Midday Pass','Heimdall Catallaxy Close Pass','Heimdall Catallaxy Logon Refresh' -Confirm:`$false"

# Registers two per-user Windows Scheduled Tasks (no admin rights required) that keep
# every panel's cached data fresh:
#   1. "Heimdall Catallaxy Daily Refresh"  - runs daily at 8:30 PM local time
#   2. "Heimdall Catallaxy Logon Refresh"  - runs whenever you log on (catch-up if the PC
#                                        was off/asleep at 8:30 PM)
# Both run refresh_all.ps1, which calls every panel's fetch script in turn. Safe to re-run
# this setup script any time - it overwrites the existing task definitions rather than
# duplicating them.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $root "refresh_all.ps1"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$dailyTrigger = New-ScheduledTaskTrigger -Daily -At "8:30PM"
Register-ScheduledTask -TaskName "Heimdall Catallaxy Daily Refresh" -Action $action -Trigger $dailyTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Daily Refresh (daily @ 8:30 PM)"

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "Heimdall Catallaxy Logon Refresh" -Action $action -Trigger $logonTrigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Output "Registered: Heimdall Catallaxy Logon Refresh (at every log on)"

Write-Output ""
Write-Output "Manage these any time via Task Scheduler (taskschd.msc), under Task Scheduler Library."
Write-Output "To remove: Unregister-ScheduledTask -TaskName 'Heimdall Catallaxy Daily Refresh','Heimdall Catallaxy Logon Refresh' -Confirm:`$false"

# Runs every fetch script in this project. This is what the scheduled tasks call, so
# adding a new panel later just means adding one more line here.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

& (Join-Path $root "fetch_btc_data.ps1")
Write-Output "---"
& (Join-Path $root "fetch_macro_data.ps1")
Write-Output "---"
& (Join-Path $root "fetch_energy_data.ps1")
Write-Output "---"
& (Join-Path $root "fetch_ai_data.ps1")
Write-Output "---"
& (Join-Path $root "fetch_credit_data.ps1")
Write-Output "---"
& (Join-Path $root "fetch_gex_data.ps1")

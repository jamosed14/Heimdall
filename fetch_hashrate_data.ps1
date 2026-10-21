# Bitcoin network hashrate + difficulty (BTC tab). Writes data\hashrate_data.js.
#
# Source: mempool.space public API, no key.
#   /api/v1/mining/hashrate/all     - daily hashrate estimate back to 2009-01-03, plus every
#                                     difficulty adjustment (time, height, difficulty, ratio).
#   /api/v1/difficulty-adjustment   - progress through the current epoch and mempool's estimate
#                                     of the next adjustment (an estimate, labeled as such).
# Hashrate is never observed directly - it's inferred from block arrival times, so a single
# day is noisy (one lucky/unlucky day swings it 10%+). The card and chart use a trailing 7-day
# average; difficulty adjustments are the exact on-chain values.
#
# Kept separate from fetch_btc_data.ps1 (Coinbase price pipeline) so a mempool.space outage can
# never affect the price/200W MA data, and vice versa.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$outPath = Join-Path $dataDir "hashrate_data.js"

$existing = Get-ExistingPayload $outPath
if ($existing) { Write-Output ("Existing cache found: generated {0}" -f $existing.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }

$UA = @{ "User-Agent" = "Heimdall Catallaxy (personal research dashboard; jamosed14@gmail.com)" }
function Invoke-WithRetry($uri) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { return Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec 60 }
        catch {
            if ($attempt -eq 3) { throw }
            Write-Host ("::warning::{0} failed (attempt {1}/3), retrying: {2}" -f $uri, $attempt, $_.Exception.Message)
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

# ---------- Fetch ----------
$freshDaily = @()
$freshAdjustments = @()
try {
    Write-Output "Fetching hashrate history from mempool.space..."
    $resp = Invoke-WithRetry "https://mempool.space/api/v1/mining/hashrate/all"
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($h in $resp.hashrates) {
        if ($null -eq $h.timestamp -or $null -eq $h.avgHashrate) { continue }
        $v = [double]$h.avgHashrate / 1e18   # H/s -> EH/s
        if ($v -le 0 -or [double]::IsNaN($v)) { continue }
        $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$h.timestamp).UtcDateTime.ToString("yyyy-MM-dd")
        $list.Add([PSCustomObject]@{ Date = $d; Value = $v })
    }
    # Dedupe by date (latest wins) before validation.
    $freshDaily = Merge-SeriesByDate -Existing @() -Fresh $list
    $adj = New-Object System.Collections.Generic.List[object]
    foreach ($a in $resp.difficulty) {
        if ($null -eq $a.time -or $null -eq $a.difficulty -or $null -eq $a.adjustment) { continue }
        $adj.Add([PSCustomObject]@{
            date       = [DateTimeOffset]::FromUnixTimeSeconds([int64]$a.time).UtcDateTime.ToString("yyyy-MM-dd")
            height     = [int64]$a.height
            difficultyT = [math]::Round([double]$a.difficulty / 1e12, 3)
            changePct  = [math]::Round(([double]$a.adjustment - 1.0) * 100.0, 2)
        })
    }
    $freshAdjustments = $adj
} catch {
    Write-Host ("::error::mempool.space hashrate fetch failed: {0}" -f $_.Exception.Message)
}

# Full history since 2009 is ~6,500 daily points - 5,000 is a floor that catches a truncated
# response. The latest point must also be recent (a frozen feed shouldn't pass as fresh).
$fresh = $freshDaily
if ($fresh.Count -gt 0) {
    $ageDays = ((Get-Date).ToUniversalTime().Date - [DateTime]::Parse($fresh[-1].Date)).TotalDays
    if ($ageDays -gt 5) {
        Write-Host ("::error::mempool.space hashrate: latest point {0} is {1} days old" -f $fresh[-1].Date, $ageDays)
        $fresh = @()
    }
}
$existingDaily = if ($existing -and $existing.series -and $existing.series.daily) { ConvertFrom-SeriesJson $existing.series.daily } else { @() }
$result = Get-ValidatedMergedSeries -Fresh $fresh -Existing $existingDaily -MinCount 5000 -Name "hashrate-mempool"
if ($result.series.Count -eq 0) { throw "No usable hashrate data (fresh fetch invalid and no cache) - refusing to write data\hashrate_data.js." }
$daily = @($result.series)

$adjustments = if ($result.status -eq "ok" -and $freshAdjustments.Count -gt 100) { $freshAdjustments }
               elseif ($existing -and $existing.adjustments) { $existing.adjustments }
               else { @() }

# Next-adjustment estimate is a live snapshot: optional, never blocks the write.
$nextAdj = $null
try {
    $na = Invoke-WithRetry "https://mempool.space/api/v1/difficulty-adjustment"
    if ($null -ne $na.difficultyChange -and $null -ne $na.estimatedRetargetDate) {
        $nextAdj = [ordered]@{
            estChangePct    = [math]::Round([double]$na.difficultyChange, 2)
            estDate         = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$na.estimatedRetargetDate).UtcDateTime.ToString("yyyy-MM-dd")
            progressPct     = [math]::Round([double]$na.progressPercent, 1)
            remainingBlocks = [int]$na.remainingBlocks
            height          = [int64]$na.nextRetargetHeight
        }
    }
} catch {
    Write-Host ("::warning::mempool.space difficulty-adjustment estimate failed: {0}" -f $_.Exception.Message)
    if ($existing -and $existing.nextAdjustment) { $nextAdj = $existing.nextAdjustment }
}

# ---------- Derive ----------
# Trailing 7-day mean of the daily estimates.
$ma7 = New-Object System.Collections.Generic.List[object]
$window = New-Object System.Collections.Generic.Queue[double]
$sum = 0.0
foreach ($p in $daily) {
    $window.Enqueue($p.Value); $sum += $p.Value
    if ($window.Count -gt 7) { $sum -= $window.Dequeue() }
    if ($window.Count -eq 7) { $ma7.Add([PSCustomObject]@{ Date = $p.Date; Value = $sum / 7.0 }) }
}
$latest7 = $ma7[$ma7.Count - 1]
$latestDate = [DateTime]::Parse($latest7.Date)
$chg30 = $null
for ($i = $ma7.Count - 1; $i -ge 0; $i--) {
    if ([DateTime]::Parse($ma7[$i].Date) -le $latestDate.AddDays(-30)) {
        $chg30 = ($latest7.Value / $ma7[$i].Value - 1.0) * 100.0
        break
    }
}
$athIdx = 0
for ($i = 1; $i -lt $ma7.Count; $i++) { if ($ma7[$i].Value -gt $ma7[$athIdx].Value) { $athIdx = $i } }
$lastAdj = if ($adjustments.Count -gt 0) { $adjustments[$adjustments.Count - 1] } else { $null }

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$payload = [ordered]@{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = if ($result.status -eq "ok") { $nowUtc } else { $existing.lastSuccessfulRefresh }
    lastObservation       = $latest7.Date
    sourceStatus          = @{ mempool = $result.status }
    source                = "mempool.space"
    stats                 = [ordered]@{
        hashrate7dEh   = [math]::Round($latest7.Value, 1)
        asOfDate       = $latest7.Date
        chg30dPct      = if ($null -ne $chg30) { [math]::Round($chg30, 2) } else { $null }
        ath7dEh        = [math]::Round($ma7[$athIdx].Value, 1)
        ath7dDate      = $ma7[$athIdx].Date
        lastAdjustment = $lastAdj
    }
    nextAdjustment        = $nextAdj
    adjustments           = @($adjustments | Select-Object -Last 30)
    # Raw daily estimates only (the merge/fail-stale base); the page computes the 7D average for
    # the chart. 5 significant digits - EH/s spans ~1e-12 (2009) to ~1e3, so fixed decimals won't do.
    series                = @{ daily = @($daily | ForEach-Object { @{ d = $_.Date; v = [double]$_.Value.ToString("G5", [System.Globalization.CultureInfo]::InvariantCulture) } }) }
}

Write-DataFileAtomic -Path $outPath -VarName "HASHRATE_DATA" -Payload $payload -Depth 6
Write-Output ("Hashrate 7D: {0} EH/s ({1}) | 30D chg: {2}% | last adj: {3} {4}% | next est: {5}% ~{6} [{7}]" -f `
    $payload.stats.hashrate7dEh, $latest7.Date, $payload.stats.chg30dPct, $lastAdj.date, $lastAdj.changePct, $nextAdj.estChangePct, $nextAdj.estDate, $result.status)

# Pulls full BTC daily price history, computes 200W MA / premium-discount / ATH / drawdown /
# realized vol, and writes data\btc_data.js for the dashboard to read (avoids file:// fetch/CORS
# issues by loading as a <script> tag instead of via fetch()).
#
# Data-integrity model (see fetch_common.ps1): the raw daily price series is validated and
# merged with the existing cached series by date before anything is derived from it - a
# truncated/empty/malformed blockchain.info response falls back to last known-good history
# rather than recomputing MA/ATH/vol from bad or partial data. CME basis (a live snapshot, not
# a history series) falls back to its last cached value on failure rather than going blank.

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$outPath = Join-Path $dataDir "btc_data.js"

$existingPayload = Get-ExistingPayload $outPath
if ($existingPayload) { Write-Output ("Existing cache found: generated {0}" -f $existingPayload.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }
# Existing payload's series is {d,p,ma} - only need the price (p) for merge/fallback purposes;
# MA/ATH/vol are always recomputed fresh from the full merged price history below.
$existingPriceSeries = if ($existingPayload) {
    , ($existingPayload.series | ForEach-Object { [PSCustomObject]@{ Date = $_.d; Value = [double]$_.p } })
} else { @() }

Write-Output "Fetching BTC price history..."
$freshPriceSeries = @()
try {
    $resp = Invoke-RestMethod -Uri "https://api.blockchain.info/charts/market-price?timespan=all&format=json&sampled=false" -UseBasicParsing -TimeoutSec 30
    $rawVals = $resp.values | Sort-Object x
    $startIdx = 0
    for ($i = 0; $i -lt $rawVals.Count; $i++) { if ($rawVals[$i].y -gt 0) { $startIdx = $i; break } }
    $list = New-Object System.Collections.Generic.List[object]
    for ($i = $startIdx; $i -lt $rawVals.Count; $i++) {
        $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$rawVals[$i].x).UtcDateTime.Date
        $list.Add([PSCustomObject]@{ Date = $d.ToString("yyyy-MM-dd"); Value = [double]$rawVals[$i].y })
    }
    # NOTE: no leading comma here - "return , (...)" is the correct idiom to stop a function
    # from unrolling its return value, but that same comma on a plain variable assignment
    # double-wraps the array instead (confirmed: produced a 1-element array whose only element
    # was the real 5842-item array). Direct assignment doesn't need it.
    $freshPriceSeries = $list | Sort-Object Date
} catch {
    Write-Host ("::error::blockchain.info fetch failed: {0}" -f $_.Exception.Message)
}

# blockchain.info history runs back to 2010 - thousands of points expected. 500 is a
# conservative floor that catches a truncated/broken response without being trigger-happy.
$priceResult = Get-ValidatedMergedSeries -Fresh $freshPriceSeries -Existing $existingPriceSeries -MinCount 500 -Name "btc-price"
if ($priceResult.series.Count -eq 0) {
    throw "No usable BTC price data (fresh fetch invalid and no existing cache) - refusing to write data\btc_data.js."
}
Write-Output ("  btc-price: {0} pts, {1} to {2} [{3}]" -f $priceResult.series.Count, $priceResult.series[0].Date, $priceResult.series[-1].Date, $priceResult.status)

$daily = $priceResult.series | ForEach-Object { [PSCustomObject]@{ Date = [DateTime]::Parse($_.Date); Price = $_.Value; MA200W = $null } }

# --- Weekly resample: last available daily close per calendar week (Mon-start) ---
$cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
$weekRule = [System.Globalization.CalendarWeekRule]::FirstFourDayWeek
$firstDay = [System.DayOfWeek]::Monday

function Get-WeekKey($date) {
    $weekNum = $cal.GetWeekOfYear($date, $weekRule, $firstDay)
    return "{0}-W{1:D2}" -f $date.Year, $weekNum
}

$weeklyMap = [ordered]@{}
foreach ($d in $daily) {
    $weeklyMap[(Get-WeekKey $d.Date)] = $d.Price
}

# Rolling 200-period SMA over weekly closes
$weeklyMA = [ordered]@{}
$window = New-Object System.Collections.Generic.Queue[double]
$sum = 0.0
foreach ($k in $weeklyMap.Keys) {
    $price = $weeklyMap[$k]
    $window.Enqueue($price)
    $sum += $price
    if ($window.Count -gt 200) { $sum -= $window.Dequeue() }
    if ($window.Count -eq 200) {
        $weeklyMA[$k] = $sum / 200.0
    } else {
        $weeklyMA[$k] = $null
    }
}

# Map each day's weekly MA back onto that day (stair-steps once per week, by design)
for ($i = 0; $i -lt $daily.Count; $i++) {
    $daily[$i].MA200W = $weeklyMA[(Get-WeekKey $daily[$i].Date)]
}

# --- ATH + drawdown ---
$athPrice = 0.0
$athDate = $null
foreach ($d in $daily) {
    if ($d.Price -gt $athPrice) { $athPrice = $d.Price; $athDate = $d.Date }
}
$currentPrice = $daily[$daily.Count - 1].Price
$drawdownPct = (($currentPrice - $athPrice) / $athPrice) * 100.0

# --- Realized vol (annualized stdev of daily log returns) ---
function Get-RealizedVol($series, $lookback) {
    $n = $series.Count
    if ($n -le $lookback) { return $null }
    $returns = New-Object System.Collections.Generic.List[double]
    for ($i = $n - $lookback; $i -lt $n; $i++) {
        $p0 = $series[$i - 1].Price
        $p1 = $series[$i].Price
        if ($p0 -gt 0 -and $p1 -gt 0) { $returns.Add([math]::Log($p1 / $p0)) }
    }
    $mean = ($returns | Measure-Object -Average).Average
    $sqDiffs = $returns | ForEach-Object { [math]::Pow($_ - $mean, 2) }
    $variance = ($sqDiffs | Measure-Object -Average).Average
    $stdDev = [math]::Sqrt($variance)
    return $stdDev * [math]::Sqrt(365) * 100.0
}

$vol30 = Get-RealizedVol -series $daily -lookback 30
$vol90 = Get-RealizedVol -series $daily -lookback 90

# --- Latest 200W MA + premium/discount ---
$latestMA = $daily[$daily.Count - 1].MA200W
$premiumPct = $null
if ($null -ne $latestMA) { $premiumPct = (($currentPrice - $latestMA) / $latestMA) * 100.0 }

# --- CME basis: front-month BTC futures vs. spot, same vendor for both so the spread is apples-to-apples.
# This is a live snapshot (not a history series) - on failure, fall back to the existing cached
# value (marked stale) rather than going blank, same "fail stale, not broken" principle. ---
function Get-LastFriday($year, $month) {
    $lastDay = [DateTime]::new($year, $month, [DateTime]::DaysInMonth($year, $month))
    while ($lastDay.DayOfWeek -ne [System.DayOfWeek]::Friday) { $lastDay = $lastDay.AddDays(-1) }
    return $lastDay
}

$monthMap = @{ Jan=1; Feb=2; Mar=3; Apr=4; May=5; Jun=6; Jul=7; Aug=8; Sep=9; Oct=10; Nov=11; Dec=12 }
$cmeBasis = $null
$cmeBasisStatus = "error"
try {
    $ua = "Mozilla/5.0"
    $futResp = Invoke-RestMethod -Uri "https://query1.finance.yahoo.com/v8/finance/chart/BTC=F?range=1d&interval=1d" -Headers @{ "User-Agent" = $ua } -TimeoutSec 30
    $spotResp = Invoke-RestMethod -Uri "https://query1.finance.yahoo.com/v8/finance/chart/BTC-USD?range=1d&interval=1d" -Headers @{ "User-Agent" = $ua } -TimeoutSec 30

    $futMeta = $futResp.chart.result[0].meta
    $futPrice = [double]$futMeta.regularMarketPrice
    $spotPrice = [double]$spotResp.chart.result[0].meta.regularMarketPrice
    $contractLabel = $futMeta.shortName

    if ($null -eq $futPrice -or $null -eq $spotPrice -or [double]::IsNaN($futPrice) -or [double]::IsNaN($spotPrice) -or $spotPrice -eq 0) {
        throw "futures/spot price missing or invalid"
    }

    $rawBasisPct = (($futPrice - $spotPrice) / $spotPrice) * 100.0

    $annualizedBasisPct = $null
    $daysToExpiry = $null
    if ($contractLabel -match "(\w{3})-(\d{4})") {
        $mon = $monthMap[$Matches[1]]
        $yr = [int]$Matches[2]
        if ($mon) {
            $expiry = Get-LastFriday -year $yr -month $mon
            $daysToExpiry = [math]::Ceiling(($expiry - (Get-Date)).TotalDays)
            if ($daysToExpiry -gt 0) {
                $annualizedBasisPct = $rawBasisPct * (365.0 / $daysToExpiry)
            }
        }
    }

    $cmeBasis = @{
        futuresPrice       = [math]::Round($futPrice, 2)
        spotPriceRef       = [math]::Round($spotPrice, 2)
        contractLabel      = $contractLabel
        rawBasisPct        = [math]::Round($rawBasisPct, 3)
        annualizedBasisPct = if ($null -ne $annualizedBasisPct) { [math]::Round($annualizedBasisPct, 2) } else { $null }
        daysToExpiry       = $daysToExpiry
    }
    $cmeBasisStatus = "ok"
    Write-Output ("CME basis: {0} vs spot {1} ({2}) -> raw {3}%, annualized {4}%, {5}d to expiry" -f `
        $futPrice, $spotPrice, $contractLabel, $cmeBasis.rawBasisPct, $cmeBasis.annualizedBasisPct, $daysToExpiry)
} catch {
    Write-Host ("::warning::CME basis fetch failed: {0}" -f $_.Exception.Message)
    if ($existingPayload -and $existingPayload.stats.cmeBasis) {
        $e = $existingPayload.stats.cmeBasis
        $cmeBasis = @{
            futuresPrice       = $e.futuresPrice
            spotPriceRef       = $e.spotPriceRef
            contractLabel      = $e.contractLabel
            rawBasisPct        = $e.rawBasisPct
            annualizedBasisPct = $e.annualizedBasisPct
            daysToExpiry       = $e.daysToExpiry
        }
        $cmeBasisStatus = "stale"
        Write-Host "::warning::CME basis: falling back to last cached value"
    } else {
        Write-Host "::error::CME basis: no fresh data and no existing cached value - will show as unavailable"
    }
}

# --- Build output payload ---
$series = foreach ($d in $daily) {
    $maVal = $null
    if ($null -ne $d.MA200W) { $maVal = [math]::Round($d.MA200W, 2) }
    @{ d = $d.Date.ToString("yyyy-MM-dd"); p = [math]::Round($d.Price, 2); ma = $maVal }
}

$statsMA = $null
if ($null -ne $latestMA) { $statsMA = [math]::Round($latestMA, 2) }
$statsPremium = $null
if ($null -ne $premiumPct) { $statsPremium = [math]::Round($premiumPct, 2) }
$statsVol30 = $null
if ($null -ne $vol30) { $statsVol30 = [math]::Round($vol30, 2) }
$statsVol90 = $null
if ($null -ne $vol90) { $statsVol90 = [math]::Round($vol90, 2) }

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$payload = @{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = $nowUtc
    lastObservation       = $daily[$daily.Count - 1].Date.ToString("yyyy-MM-dd")
    sourceStatus          = @{ blockchainInfo = $priceResult.status; cmeBasis = $cmeBasisStatus }
    asOfDate              = $daily[$daily.Count - 1].Date.ToString("yyyy-MM-dd")
    series                = $series
    stats                 = @{
        price       = [math]::Round($currentPrice, 2)
        ma200w      = $statsMA
        premiumPct  = $statsPremium
        athPrice    = [math]::Round($athPrice, 2)
        athDate     = $athDate.ToString("yyyy-MM-dd")
        drawdownPct = [math]::Round($drawdownPct, 2)
        vol30dPct   = $statsVol30
        vol90dPct   = $statsVol90
        cmeBasis    = $cmeBasis
    }
}

Write-DataFileAtomic -Path $outPath -VarName "BTC_DATA" -Payload $payload -Depth 6
Write-Output ("Price: {0}  200W MA: {1}  Premium: {2}%  ATH: {3} ({4})  Drawdown: {5}%  Vol30D: {6}%  Vol90D: {7}%" -f `
    $currentPrice, $statsMA, $statsPremium, $athPrice, $payload.stats.athDate, $drawdownPct, $statsVol30, $statsVol90)

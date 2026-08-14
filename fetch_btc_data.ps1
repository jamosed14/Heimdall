# Pulls full BTC daily price history, computes 200W MA / premium-discount / ATH / drawdown /
# realized vol, and writes data\btc_data.js for the dashboard to read (avoids file:// fetch/CORS
# issues by loading as a <script> tag instead of via fetch()).

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

Write-Output "Fetching BTC price history..."
$resp = Invoke-RestMethod -Uri "https://api.blockchain.info/charts/market-price?timespan=all&format=json&sampled=false" -UseBasicParsing

$raw = $resp.values | Sort-Object x
$startIdx = 0
for ($i = 0; $i -lt $raw.Count; $i++) {
    if ($raw[$i].y -gt 0) { $startIdx = $i; break }
}

$daily = @()
for ($i = $startIdx; $i -lt $raw.Count; $i++) {
    $daily += [PSCustomObject]@{
        Date   = [DateTimeOffset]::FromUnixTimeSeconds([int64]$raw[$i].x).UtcDateTime.Date
        Price  = [double]$raw[$i].y
        MA200W = $null
    }
}

Write-Output ("Loaded {0} daily price points, {1} to {2}" -f $daily.Count, $daily[0].Date.ToString("yyyy-MM-dd"), $daily[-1].Date.ToString("yyyy-MM-dd"))

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

# --- CME basis: front-month BTC futures vs. spot, same vendor for both so the spread is apples-to-apples ---
function Get-LastFriday($year, $month) {
    $lastDay = [DateTime]::new($year, $month, [DateTime]::DaysInMonth($year, $month))
    while ($lastDay.DayOfWeek -ne [System.DayOfWeek]::Friday) { $lastDay = $lastDay.AddDays(-1) }
    return $lastDay
}

$monthMap = @{ Jan=1; Feb=2; Mar=3; Apr=4; May=5; Jun=6; Jul=7; Aug=8; Sep=9; Oct=10; Nov=11; Dec=12 }
$cmeBasis = $null
try {
    $ua = "Mozilla/5.0"
    $futResp = Invoke-RestMethod -Uri "https://query1.finance.yahoo.com/v8/finance/chart/BTC=F?range=1d&interval=1d" -Headers @{ "User-Agent" = $ua }
    $spotResp = Invoke-RestMethod -Uri "https://query1.finance.yahoo.com/v8/finance/chart/BTC-USD?range=1d&interval=1d" -Headers @{ "User-Agent" = $ua }

    $futMeta = $futResp.chart.result[0].meta
    $futPrice = [double]$futMeta.regularMarketPrice
    $spotPrice = [double]$spotResp.chart.result[0].meta.regularMarketPrice
    $contractLabel = $futMeta.shortName

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
    Write-Output ("CME basis: {0} vs spot {1} ({2}) -> raw {3}%, annualized {4}%, {5}d to expiry" -f `
        $futPrice, $spotPrice, $contractLabel, $cmeBasis.rawBasisPct, $cmeBasis.annualizedBasisPct, $daysToExpiry)
} catch {
    Write-Output ("CME basis fetch failed, leaving null: {0}" -f $_.Exception.Message)
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

$payload = @{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    asOfDate       = $daily[$daily.Count - 1].Date.ToString("yyyy-MM-dd")
    series         = $series
    stats          = @{
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

$json = $payload | ConvertTo-Json -Depth 6 -Compress
$jsOut = "window.BTC_DATA = $json;"
$outPath = Join-Path $dataDir "btc_data.js"
Set-Content -Path $outPath -Value $jsOut -Encoding UTF8

Write-Output "Wrote $outPath"
Write-Output ("Price: {0}  200W MA: {1}  Premium: {2}%  ATH: {3} ({4})  Drawdown: {5}%  Vol30D: {6}%  Vol90D: {7}%" -f `
    $currentPrice, $statsMA, $statsPremium, $athPrice, $payload.stats.athDate, $drawdownPct, $statsVol30, $statsVol90)

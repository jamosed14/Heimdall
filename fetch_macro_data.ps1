# Single fetch pass for every non-BTC series used across Summary / Rates / Fed & Liquidity /
# Inflation / Dollar & FX. Each underlying series (FRED or Yahoo) is pulled exactly once here,
# even though several tabs display it - this is the single source of truth for macro data.
# Writes data\macro_data.js (script tag, not fetch(), to avoid file:// CORS issues).

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fred_config.ps1")

$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$START_DATE = "2003-01-01"

# ===================== Fetch =====================

function Get-FredSeriesLastUpdated($seriesId) {
    $uri = "https://api.stlouisfed.org/fred/series?series_id=$seriesId&api_key=$FRED_API_KEY&file_type=json"
    $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing
    return ($resp.seriess[0].last_updated -split " ")[0]
}

function Get-FredSeries($seriesId) {
    $uri = "https://api.stlouisfed.org/fred/series/observations?series_id=$seriesId&api_key=$FRED_API_KEY&file_type=json&observation_start=$START_DATE"
    $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($o in $resp.observations) {
        if ($o.value -ne ".") { $out.Add([PSCustomObject]@{ Date = $o.date; Value = [double]$o.value }) }
    }
    return , ($out | Sort-Object Date)
}

function Get-YahooDaily($symbol) {
    $uri = "https://query1.finance.yahoo.com/v8/finance/chart/$symbol`?range=5y&interval=1d"
    $resp = Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = "Mozilla/5.0" } -UseBasicParsing
    $result = $resp.chart.result[0]
    $ts = $result.timestamp
    $closes = $result.indicators.quote[0].close
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ts.Count; $i++) {
        if ($null -ne $closes[$i]) {
            $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ts[$i]).UtcDateTime.ToString("yyyy-MM-dd")
            $out.Add([PSCustomObject]@{ Date = $d; Value = [double]$closes[$i] })
        }
    }
    return , ($out | Sort-Object Date)
}

Write-Output "Fetching FRED series..."
$fredIds = @(
    "DFF", "SOFR",
    "DGS3MO", "DGS2", "DGS5", "DGS10", "DGS30", "DFII10",
    "WALCL", "WRESBAL", "WTREGEN", "RRPONTSYD",
    "T5YIE", "T10YIE",
    "CPIAUCSL", "CPILFESL", "PCEPI", "PCEPILFE",
    "DEXUSEU", "DEXJPUS", "DEXUSUK", "DEXCHUS",
    "FEDTARMD", "FEDTARMDLR",
    "MEDCPIM158SFRBCLE", "TRMMEANCPIM158SFRBCLE", "STICKCPIM157SFRBATL", "CORESTICKM159SFRBATL",
    "M2SL", "GDP", "M2V"
)
$raw = @{}
foreach ($id in $fredIds) {
    $raw[$id] = Get-FredSeries $id
    Write-Output ("  {0}: {1} points, latest {2} = {3}" -f $id, $raw[$id].Count, $raw[$id][-1].Date, $raw[$id][-1].Value)
}

Write-Output "Fetching Yahoo DXY..."
try {
    $raw["DXY"] = Get-YahooDaily "DX-Y.NYB"
    Write-Output ("  DXY: {0} points, latest {1} = {2}" -f $raw["DXY"].Count, $raw["DXY"][-1].Date, $raw["DXY"][-1].Value)
} catch {
    $raw["DXY"] = @()
    Write-Output ("  DXY fetch failed: {0}" -f $_.Exception.Message)
}

# 30-Day Fed Funds futures (ZQ, CBOT/CME) - one contract per calendar month, next 13 months.
# Each contract's quoted price is an IMM index; implied average EFFR for that month = 100 - price.
Write-Output "Fetching CME 30-Day Fed Funds futures (ZQ)..."
function Get-ZQContracts($count) {
    $codes = @('F', 'G', 'H', 'J', 'K', 'M', 'N', 'Q', 'U', 'V', 'X', 'Z')
    $today = Get-Date
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $count; $i++) {
        $d = $today.AddMonths($i)
        $code = $codes[$d.Month - 1]
        $yy = ($d.Year % 100).ToString("D2")
        $out.Add([PSCustomObject]@{
            Ticker = "ZQ$code$yy.CBT"
            Year   = $d.Year
            Month  = $d.Month
            Label  = $d.ToString("MMM yyyy")
        })
    }
    return $out
}

$zqContracts = Get-ZQContracts 13
$zqRaw = @{}
foreach ($c in $zqContracts) {
    try {
        $hist = Get-YahooDaily $c.Ticker
        if ($hist.Count -gt 0) {
            $zqRaw[$c.Ticker] = $hist
            Write-Output ("  {0} ({1}): {2} points, latest {3} = {4}" -f $c.Ticker, $c.Label, $hist.Count, $hist[-1].Date, $hist[-1].Value)
        } else {
            Write-Output ("  {0} ({1}): no data, skipped" -f $c.Ticker, $c.Label)
        }
    } catch {
        Write-Output ("  {0} ({1}) fetch failed, skipped: {2}" -f $c.Ticker, $c.Label, $_.Exception.Message)
    }
}

# ===================== Helpers =====================

function New-DateMap($series) {
    $m = @{}
    foreach ($p in $series) { $m[$p.Date] = $p.Value }
    return $m
}

function Get-Spread($seriesA, $seriesB) {
    # seriesA - seriesB, matched by date
    $mapB = New-DateMap $seriesB
    return , $(foreach ($p in $seriesA) {
        if ($mapB.ContainsKey($p.Date)) { [PSCustomObject]@{ Date = $p.Date; Value = $p.Value - $mapB[$p.Date] } }
    })
}

function Get-Rescaled($series, $factor) {
    return , $(foreach ($p in $series) { [PSCustomObject]@{ Date = $p.Date; Value = $p.Value * $factor } })
}

function Get-Changes($series) {
    # sorted ascending by Date, one print per row
    $n = $series.Count
    if ($n -eq 0) { return @{ value = $null; asOfDate = $null; chg1d = $null; chg1w = $null; chg1m = $null; chgYtd = $null } }
    $latest = $series[$n - 1]
    $latestDate = [DateTime]::Parse($latest.Date)
    $yearStart = [DateTime]::new($latestDate.Year, 1, 1)

    $chg1d = $null
    if ($n -ge 2) { $chg1d = $latest.Value - $series[$n - 2].Value }

    function Find-LookbackChange($days) {
        $targetDate = $latestDate.AddDays(-$days)
        for ($i = $n - 1; $i -ge 0; $i--) {
            $d = [DateTime]::Parse($series[$i].Date)
            if ($d -le $targetDate) { return $latest.Value - $series[$i].Value }
        }
        return $null
    }

    $chgYtd = $null
    for ($i = 0; $i -lt $n; $i++) {
        $d = [DateTime]::Parse($series[$i].Date)
        if ($d -ge $yearStart) { $chgYtd = $latest.Value - $series[$i].Value; break }
    }

    return @{
        value    = $latest.Value
        asOfDate = $latest.Date
        chg1d    = $chg1d
        chg1w    = Find-LookbackChange 7
        chg1m    = Find-LookbackChange 30
        chgYtd   = $chgYtd
    }
}

function Round-Stat($stat, $digits, $freq) {
    $r = @{ asOfDate = $stat.asOfDate; freq = $freq }
    foreach ($k in @("value", "chg1d", "chg1w", "chg1m", "chgYtd")) {
        $v = $stat[$k]
        $r[$k] = if ($null -ne $v) { [math]::Round($v, $digits) } else { $null }
    }
    return $r
}

function Get-YoySeries($indexSeries) {
    # index[t] / index[t-12 months] - 1, matched by exact "12 months prior" calendar date on a monthly series
    $map = New-DateMap $indexSeries
    return , $(foreach ($p in $indexSeries) {
        $d = [DateTime]::Parse($p.Date)
        $priorDate = $d.AddMonths(-12).ToString("yyyy-MM-dd")
        if ($map.ContainsKey($priorDate)) {
            [PSCustomObject]@{ Date = $p.Date; Value = (($p.Value / $map[$priorDate]) - 1.0) * 100.0 }
        }
    })
}

function Get-MonthlyStat($yoySeries) {
    $n = $yoySeries.Count
    if ($n -eq 0) { return @{ value = $null; asOfDate = $null; priorValue = $null; priorDate = $null; freq = "monthly" } }
    $latest = $yoySeries[$n - 1]
    $r = @{ value = [math]::Round($latest.Value, 2); asOfDate = $latest.Date; freq = "monthly" }
    if ($n -ge 2) {
        $r["priorValue"] = [math]::Round($yoySeries[$n - 2].Value, 2)
        $r["priorDate"] = $yoySeries[$n - 2].Date
    } else {
        $r["priorValue"] = $null; $r["priorDate"] = $null
    }
    return $r
}

function To-SeriesJson($series, $digits) {
    return , $(foreach ($p in $series) { @{ d = $p.Date; v = [math]::Round($p.Value, $digits) } })
}

# ===================== Derived series =====================

Write-Output "Computing derived series..."
$spread2s10 = Get-Spread $raw["DGS10"] $raw["DGS2"]
$spread3m10 = Get-Spread $raw["DGS10"] $raw["DGS3MO"]
$spread5s30 = Get-Spread $raw["DGS30"] $raw["DGS5"]

$walclB = Get-Rescaled $raw["WALCL"] (1.0 / 1000.0)
$wresbalB = Get-Rescaled $raw["WRESBAL"] (1.0 / 1000.0)
$wtregenB = Get-Rescaled $raw["WTREGEN"] (1.0 / 1000.0)

$rrpMap = New-DateMap $raw["RRPONTSYD"]
$rrpDatesSorted = $raw["RRPONTSYD"] | ForEach-Object { $_.Date }
function Get-NearestOnOrBefore($sortedDates, $targetDate) {
    $best = $null
    foreach ($d in $sortedDates) { if ($d -le $targetDate) { $best = $d } else { break } }
    return $best
}
$wtregenBMap = New-DateMap $wtregenB
$netLiquidity = foreach ($p in $walclB) {
    if ($wtregenBMap.ContainsKey($p.Date)) {
        $rrpDate = Get-NearestOnOrBefore $rrpDatesSorted $p.Date
        if ($rrpDate) {
            [PSCustomObject]@{ Date = $p.Date; Value = $p.Value - $wtregenBMap[$p.Date] - $rrpMap[$rrpDate] }
        }
    }
}

$cpiYoY = Get-YoySeries $raw["CPIAUCSL"]
$coreCpiYoY = Get-YoySeries $raw["CPILFESL"]
$pceYoY = Get-YoySeries $raw["PCEPI"]
$corePceYoY = Get-YoySeries $raw["PCEPILFE"]
$m2YoY = Get-YoySeries $raw["M2SL"]

# M2 / Nominal GDP (both in current dollars - GDPC1/real GDP would be a units mismatch
# against nominal M2), at GDP's quarterly cadence (nearest M2 print on or before each GDP date)
$m2DatesSorted = $raw["M2SL"] | ForEach-Object { $_.Date }
$m2Map = New-DateMap $raw["M2SL"]
$m2OverNominalGdp = foreach ($p in $raw["GDP"]) {
    $m2Date = Get-NearestOnOrBefore $m2DatesSorted $p.Date
    if ($m2Date) {
        [PSCustomObject]@{ Date = $p.Date; Value = ($m2Map[$m2Date] / $p.Value) * 100.0 }
    }
}

# Heimdall calcs, base = first available CPI print in our fetch window (2003-01-01).
# Purchasing-power index: falls as prices rise (100 * CPI_start / CPI_t).
# Price-level index: rises as prices rise (100 * CPI_t / CPI_start) - the mirror framing.
$cpiBase = $raw["CPIAUCSL"][0].Value
$purchasingPowerIndex = foreach ($p in $raw["CPIAUCSL"]) {
    [PSCustomObject]@{ Date = $p.Date; Value = 100.0 * $cpiBase / $p.Value }
}
$priceLevelIndex = foreach ($p in $raw["CPIAUCSL"]) {
    [PSCustomObject]@{ Date = $p.Date; Value = 100.0 * $p.Value / $cpiBase }
}

# ===================== Stat blocks =====================

Write-Output "Computing changes..."

$rates = @{
    y3mo       = Round-Stat (Get-Changes $raw["DGS3MO"]) 2 "daily"
    y2         = Round-Stat (Get-Changes $raw["DGS2"]) 2 "daily"
    y5         = Round-Stat (Get-Changes $raw["DGS5"]) 2 "daily"
    y10        = Round-Stat (Get-Changes $raw["DGS10"]) 2 "daily"
    y30        = Round-Stat (Get-Changes $raw["DGS30"]) 2 "daily"
    real10     = Round-Stat (Get-Changes $raw["DFII10"]) 2 "daily"
    spread2s10 = Round-Stat (Get-Changes $spread2s10) 2 "daily"
    spread3m10 = Round-Stat (Get-Changes $spread3m10) 2 "daily"
    spread5s30 = Round-Stat (Get-Changes $spread5s30) 2 "daily"
}

$fedLiquidity = @{
    fedFunds     = Round-Stat (Get-Changes $raw["DFF"]) 2 "daily"
    sofr         = Round-Stat (Get-Changes $raw["SOFR"]) 2 "daily"
    fedAssets    = Round-Stat (Get-Changes $walclB) 1 "weekly"
    reserves     = Round-Stat (Get-Changes $wresbalB) 1 "weekly"
    tga          = Round-Stat (Get-Changes $wtregenB) 1 "weekly"
    rrp          = Round-Stat (Get-Changes $raw["RRPONTSYD"]) 1 "daily"
    netLiquidity = Round-Stat (Get-Changes $netLiquidity) 1 "weekly"
}

$inflation = @{
    cpiYoY       = Get-MonthlyStat $cpiYoY
    coreCpiYoY   = Get-MonthlyStat $coreCpiYoY
    pceYoY       = Get-MonthlyStat $pceYoY
    corePceYoY   = Get-MonthlyStat $corePceYoY
    breakeven5y  = Round-Stat (Get-Changes $raw["T5YIE"]) 2 "daily"
    breakeven10y = Round-Stat (Get-Changes $raw["T10YIE"]) 2 "daily"
    medianCpi    = Get-MonthlyStat $raw["MEDCPIM158SFRBCLE"]
    trimmedCpi   = Get-MonthlyStat $raw["TRMMEANCPIM158SFRBCLE"]
    stickyCpi    = Get-MonthlyStat $raw["STICKCPIM157SFRBATL"]
    coreStickyCpi = Get-MonthlyStat $raw["CORESTICKM159SFRBATL"]
    m2           = Round-Stat (Get-Changes $raw["M2SL"]) 0 "monthly"
    m2YoY        = Get-MonthlyStat $m2YoY
    m2OverNominalGdp = Round-Stat (Get-Changes $m2OverNominalGdp) 2 "quarterly"
    m2Velocity   = Round-Stat (Get-Changes $raw["M2V"]) 3 "quarterly"
    purchasingPower = Round-Stat (Get-Changes $purchasingPowerIndex) 1 "monthly"
    priceLevel   = Round-Stat (Get-Changes $priceLevelIndex) 1 "monthly"
    cpiBaseDate  = $raw["CPIAUCSL"][0].Date
}

Write-Output "Computing Fed Funds futures implied path..."
$currentEffr = $raw["DFF"][-1].Value
$fedPath = New-Object System.Collections.Generic.List[object]
foreach ($c in $zqContracts) {
    if (-not $zqRaw.ContainsKey($c.Ticker)) { continue }
    $hist = $zqRaw[$c.Ticker]
    $latest = $hist[-1]
    $impliedRate = 100.0 - $latest.Value
    $changeBps = ($impliedRate - $currentEffr) * 100.0
    $impliedHistory = $hist | ForEach-Object { [PSCustomObject]@{ Date = $_.Date; Value = 100.0 - $_.Value } }
    $fedPath.Add(@{
        ticker       = $c.Ticker
        label        = $c.Label
        year         = $c.Year
        month        = $c.Month
        futuresClose = [math]::Round($latest.Value, 3)
        impliedRate  = [math]::Round($impliedRate, 3)
        changeBps    = [math]::Round($changeBps, 1)
        asOfDate     = $latest.Date
        history      = To-SeriesJson $impliedHistory 3
    })
}

# FOMC dot plot (median SEP projections) - conceptually distinct from market-implied pricing above.
$dotPlotProjections = foreach ($p in $raw["FEDTARMD"]) {
    @{ year = [DateTime]::Parse($p.Date).Year; medianRate = [math]::Round($p.Value, 2) }
}
$dotPlotLongerRun = $null
if ($raw["FEDTARMDLR"].Count -gt 0) { $dotPlotLongerRun = [math]::Round($raw["FEDTARMDLR"][-1].Value, 2) }
$dotPlotAsOf = Get-FredSeriesLastUpdated "FEDTARMD"

$fedExpectations = @{
    currentEffr   = [math]::Round($currentEffr, 2)
    currentAsOf   = $raw["DFF"][-1].Date
    path          = $fedPath
    dotPlot       = @{
        projections = $dotPlotProjections
        longerRun   = $dotPlotLongerRun
        asOfDate    = $dotPlotAsOf
    }
}

$fx = @{
    dxy    = Round-Stat (Get-Changes $raw["DXY"]) 2 "daily"
    eurusd = Round-Stat (Get-Changes $raw["DEXUSEU"]) 4 "daily"
    usdjpy = Round-Stat (Get-Changes $raw["DEXJPUS"]) 2 "daily"
    gbpusd = Round-Stat (Get-Changes $raw["DEXUSUK"]) 4 "daily"
    usdcny = Round-Stat (Get-Changes $raw["DEXCHUS"]) 4 "daily"
}

# ===================== Chartable history series =====================

$series = @{
    y3mo         = To-SeriesJson $raw["DGS3MO"] 2
    y2           = To-SeriesJson $raw["DGS2"] 2
    y5           = To-SeriesJson $raw["DGS5"] 2
    y10          = To-SeriesJson $raw["DGS10"] 2
    y30          = To-SeriesJson $raw["DGS30"] 2
    real10       = To-SeriesJson $raw["DFII10"] 2
    spread2s10   = To-SeriesJson $spread2s10 2
    spread3m10   = To-SeriesJson $spread3m10 2
    spread5s30   = To-SeriesJson $spread5s30 2
    fedAssets    = To-SeriesJson $walclB 1
    reserves     = To-SeriesJson $wresbalB 1
    tga          = To-SeriesJson $wtregenB 1
    rrp          = To-SeriesJson $raw["RRPONTSYD"] 1
    netLiquidity = To-SeriesJson $netLiquidity 1
    cpiYoY       = To-SeriesJson $cpiYoY 2
    coreCpiYoY   = To-SeriesJson $coreCpiYoY 2
    pceYoY       = To-SeriesJson $pceYoY 2
    corePceYoY   = To-SeriesJson $corePceYoY 2
    breakeven5y  = To-SeriesJson $raw["T5YIE"] 2
    breakeven10y = To-SeriesJson $raw["T10YIE"] 2
    dxy          = To-SeriesJson $raw["DXY"] 2
    eurusd       = To-SeriesJson $raw["DEXUSEU"] 4
    usdjpy       = To-SeriesJson $raw["DEXJPUS"] 2
    medianCpi    = To-SeriesJson $raw["MEDCPIM158SFRBCLE"] 2
    trimmedCpi   = To-SeriesJson $raw["TRMMEANCPIM158SFRBCLE"] 2
    stickyCpi    = To-SeriesJson $raw["STICKCPIM157SFRBATL"] 2
    coreStickyCpi = To-SeriesJson $raw["CORESTICKM159SFRBATL"] 2
    m2YoY        = To-SeriesJson $m2YoY 2
    m2OverNominalGdp = To-SeriesJson $m2OverNominalGdp 2
    m2Velocity   = To-SeriesJson $raw["M2V"] 3
    purchasingPower = To-SeriesJson $purchasingPowerIndex 2
    priceLevel   = To-SeriesJson $priceLevelIndex 2
}

# Current yield curve snapshot (today, 1M ago, 1Y ago) across headline maturities
function Get-CurveSnapshot($daysAgo) {
    $maturities = @(
        @{ key = "3M"; id = "DGS3MO" }, @{ key = "2Y"; id = "DGS2" }, @{ key = "5Y"; id = "DGS5" },
        @{ key = "10Y"; id = "DGS10" }, @{ key = "30Y"; id = "DGS30" }
    )
    $latestDate = [DateTime]::Parse($raw["DGS10"][-1].Date)
    $targetDate = $latestDate.AddDays(-$daysAgo).ToString("yyyy-MM-dd")
    $point = @{}
    foreach ($m in $maturities) {
        $s = $raw[$m.id]
        $best = $null
        for ($i = $s.Count - 1; $i -ge 0; $i--) {
            if ($s[$i].Date -le $targetDate) { $best = $s[$i].Value; break }
        }
        $point[$m.key] = $best
    }
    return $point
}

$yieldCurve = @{
    maturityOrder = @("3M", "2Y", "5Y", "10Y", "30Y")
    now           = Get-CurveSnapshot 0
    oneMonthAgo   = Get-CurveSnapshot 30
    oneYearAgo    = Get-CurveSnapshot 365
}

# ===================== Write payload =====================

$payload = @{
    generatedAtUtc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    rates           = $rates
    fedLiquidity    = $fedLiquidity
    fedExpectations = $fedExpectations
    inflation       = $inflation
    fx              = $fx
    yieldCurve      = $yieldCurve
    series          = $series
}

$json = $payload | ConvertTo-Json -Depth 8 -Compress
$jsOut = "window.MACRO_DATA = $json;"
$outPath = Join-Path $dataDir "macro_data.js"
Set-Content -Path $outPath -Value $jsOut -Encoding UTF8

Write-Output "Wrote $outPath"

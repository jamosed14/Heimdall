# Broad public credit-market data (FRED ICE BofA OAS indices only - no single-name CDS/TRACE/
# DTCC/lending-standards/issuer bonds yet, that's future work). Answers: is the market becoming
# more or less willing to bear credit risk, and where in the quality spectrum is stress
# appearing? Writes data\credit_data.js.
#
# All six ICE BofA OAS series currently only have FRED history back to 2023-08-15 (a known FRED/
# ICE licensing restriction - these series used to carry much longer history). Percentiles below
# are computed over that actual available window, not "all-time", and the window is reported
# alongside every percentile so it's never presented as more history than really exists.
#
# Data-integrity model (see fetch_common.ps1): each of the 6 raw series is fetched, validated,
# and merged with its own existing cached series independently - one bad/blocked FRED call falls
# back to that series' last known-good data (marked "stale" in sourceStatus) without touching
# the other five. The file is only ever replaced via atomic temp-file-then-rename.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
# Local dev: dot-source the gitignored config file. CI (GitHub Actions): fall back to the
# FRED_API_KEY env var, populated from a repo secret - the key is never written to disk there.
$fredConfigPath = Join-Path $root "fred_config.ps1"
if (Test-Path $fredConfigPath) {
    . $fredConfigPath
} elseif ($env:FRED_API_KEY) {
    $FRED_API_KEY = $env:FRED_API_KEY
} else {
    throw "FRED_API_KEY not found - create fred_config.ps1 locally or set the FRED_API_KEY env var/secret in CI."
}

$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$outPath = Join-Path $dataDir "credit_data.js"

$existingPayload = Get-ExistingPayload $outPath
if ($existingPayload) { Write-Output ("Existing cache found: generated {0}" -f $existingPayload.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }

# Never throws - a network/HTTP failure here becomes an empty array, which Test-SeriesSane
# rejects and Get-ValidatedMergedSeries then falls back to the existing cached series for.
function Get-FredSeries($seriesId) {
    try {
        # 1990-01-01 is far earlier than any of these series' actual start - guarantees we
        # always get the full available history regardless of how far back FRED's window runs.
        $uri = "https://api.stlouisfed.org/fred/series/observations?series_id=$seriesId&api_key=$FRED_API_KEY&file_type=json&observation_start=1990-01-01"
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($o in $resp.observations) {
            if ($o.value -ne ".") { $out.Add([PSCustomObject]@{ Date = $o.date; Value = [double]$o.value * 100.0 }) }
        }
        return , ($out | Sort-Object Date)
    } catch {
        Write-Output ("::error::FRED fetch failed for {0}: {1}" -f $seriesId, $_.Exception.Message)
        return @()
    }
}

Write-Output "Fetching FRED credit OAS series..."
$SERIES_IDS = [ordered]@{
    ig  = "BAMLC0A0CM"
    bbb = "BAMLC0A4CBBB"
    bb  = "BAMLH0A1HYBB"
    b   = "BAMLH0A2HYB"
    ccc = "BAMLH0A3HYC"
    hy  = "BAMLH0A0HYM2"
}
# Minimum plausible observation count for a series with ~3 years of daily-weekday data (roughly
# 750 trading days) - well below that means something's wrong, not just "a bit less history".
$MIN_COUNT = 200

$raw = @{}
$sourceStatus = @{}
foreach ($key in $SERIES_IDS.Keys) {
    $fresh = Get-FredSeries $SERIES_IDS[$key]
    $existingSeries = if ($existingPayload) { ConvertFrom-SeriesJson $existingPayload.series.$key } else { @() }
    $result = Get-ValidatedMergedSeries -Fresh $fresh -Existing $existingSeries -MinCount $MIN_COUNT -Name $key
    $raw[$key] = $result.series
    $sourceStatus[$key] = $result.status
    $s = $raw[$key]
    if ($s.Count -gt 0) {
        Write-Output ("  {0} ({1}): {2} pts, {3} to {4}, latest = {5}bp [{6}]" -f $key, $SERIES_IDS[$key], $s.Count, $s[0].Date, $s[-1].Date, $s[-1].Value, $result.status)
    } else {
        Write-Output ("  {0} ({1}): NO DATA available (fresh and cached both empty) [{2}]" -f $key, $SERIES_IDS[$key], $result.status)
    }
}

# If every single series has nothing usable (fresh failed AND no cache existed for any of
# them - only possible on a first-ever run against a fully unreachable FRED), abort without
# writing rather than publish an all-empty shell.
$anyUsable = ($raw.Values | Where-Object { $_.Count -gt 0 } | Measure-Object).Count -gt 0
if (-not $anyUsable) {
    throw "All six credit series are empty (no fresh data and no existing cache for any of them) - refusing to write data\credit_data.js."
}

# ===================== Helpers =====================

function New-DateMap($series) {
    $m = @{}
    foreach ($p in $series) { $m[$p.Date] = $p.Value }
    return $m
}

# Basis-point changes over 1W/1M/3M, using the nearest available observation ON OR BEFORE each
# lookback date - never forward-filled, never assumes a weekend has a new print.
function Get-BpChanges($series) {
    $n = $series.Count
    if ($n -eq 0) { return @{ value = $null; asOfDate = $null; chg1w = $null; chg1m = $null; chg3m = $null } }
    $latest = $series[$n - 1]
    $latestDate = [DateTime]::Parse($latest.Date)

    function Find-LookbackChange($days) {
        $targetDate = $latestDate.AddDays(-$days)
        for ($i = $n - 1; $i -ge 0; $i--) {
            $d = [DateTime]::Parse($series[$i].Date)
            if ($d -le $targetDate) { return $latest.Value - $series[$i].Value }
        }
        return $null
    }

    return @{
        value    = $latest.Value
        asOfDate = $latest.Date
        chg1w    = Find-LookbackChange 7
        chg1m    = Find-LookbackChange 30
        chg3m    = Find-LookbackChange 91
    }
}

# Percentile rank of the latest value within the series' own available history (% of
# observations at or below the current level). windowStart/windowEnd describe the actual
# available window so the UI never implies "all-time" when it's really ~3 years.
function Get-Percentile($series) {
    $n = $series.Count
    if ($n -eq 0) { return @{ pct = $null; windowStart = $null; windowEnd = $null } }
    $latestVal = $series[$n - 1].Value
    $countAtOrBelow = 0
    foreach ($p in $series) { if ($p.Value -le $latestVal) { $countAtOrBelow++ } }
    return @{
        pct         = [math]::Round(($countAtOrBelow / $n) * 100.0, 0)
        windowStart = $series[0].Date
        windowEnd   = $series[$n - 1].Date
    }
}

# Finds the observation nearest to (but not after) targetDate - for the quality-curve
# "1 month ago" / "3 months ago" comparison snapshots.
function Get-NearestOnOrBefore($series, $targetDate) {
    $best = $null
    foreach ($p in $series) {
        if ([DateTime]::Parse($p.Date) -le $targetDate) { $best = $p } else { break }
    }
    return $best
}

# CALC spread: seriesA - seriesB, matched by EXACT shared observation date only (never
# forward-filled or nearest-matched) - both sides must have a real print on that date.
function Get-AlignedSpread($seriesA, $seriesB) {
    if ($seriesA.Count -eq 0 -or $seriesB.Count -eq 0) { return @() }
    $mapB = New-DateMap $seriesB
    return , $(foreach ($p in $seriesA) {
        if ($mapB.ContainsKey($p.Date)) { [PSCustomObject]@{ Date = $p.Date; Value = $p.Value - $mapB[$p.Date] } }
    })
}

function To-SeriesJson($series) {
    return , $(foreach ($p in $series) { @{ d = $p.Date; v = [math]::Round($p.Value, 1) } })
}

# ===================== Top cards =====================

Write-Output "Computing changes and percentiles..."
$cards = @{}
foreach ($key in @("ig", "bbb", "bb", "b", "ccc", "hy")) {
    $chg = Get-BpChanges $raw[$key]
    $pct = Get-Percentile $raw[$key]
    $cards[$key] = @{
        value       = if ($null -ne $chg.value) { [math]::Round($chg.value, 0) } else { $null }
        asOfDate    = $chg.asOfDate
        chg1w       = if ($null -ne $chg.chg1w) { [math]::Round($chg.chg1w, 0) } else { $null }
        chg1m       = if ($null -ne $chg.chg1m) { [math]::Round($chg.chg1m, 0) } else { $null }
        chg3m       = if ($null -ne $chg.chg3m) { [math]::Round($chg.chg3m, 0) } else { $null }
        percentile  = $pct.pct
        windowStart = $pct.windowStart
        windowEnd   = $pct.windowEnd
    }
}

# ===================== Quality curve (current / 1mo ago / 3mo ago) =====================

Write-Output "Building quality curve snapshots..."
$QUALITY_ORDER = @("ig", "bbb", "bb", "b", "ccc")
$anchorSeries = ($QUALITY_ORDER | Where-Object { $raw[$_].Count -gt 0 } | Select-Object -First 1)
if ($anchorSeries) {
    $latestDate = [DateTime]::Parse($raw[$anchorSeries][$raw[$anchorSeries].Count - 1].Date)
} else {
    $latestDate = (Get-Date).ToUniversalTime()
}
$oneMonthAgo = $latestDate.AddDays(-30)
$threeMonthsAgo = $latestDate.AddDays(-91)

function Get-CurveSnapshot($targetDate) {
    $point = @{}
    foreach ($key in $QUALITY_ORDER) {
        $obs = Get-NearestOnOrBefore $raw[$key] $targetDate
        $point[$key] = if ($obs) { [math]::Round($obs.Value, 0) } else { $null }
    }
    return $point
}
$qualityCurve = @{
    order       = $QUALITY_ORDER
    labels      = @{ ig = "IG"; bbb = "BBB"; bb = "BB"; b = "B"; ccc = "CCC" }
    current     = Get-CurveSnapshot $latestDate
    oneMonthAgo = Get-CurveSnapshot $oneMonthAgo
    threeMonthsAgo = Get-CurveSnapshot $threeMonthsAgo
    asOfDate    = $latestDate.ToString("yyyy-MM-dd")
}

# ===================== Risk dispersion (Heimdall calc, date-aligned) =====================

Write-Output "Computing risk dispersion (CALC)..."
$cccMinusBbb = Get-AlignedSpread $raw["ccc"] $raw["bbb"]
$hyMinusIg = Get-AlignedSpread $raw["hy"] $raw["ig"]
$bMinusBbb = Get-AlignedSpread $raw["b"] $raw["bbb"]

$dispersion = @{
    cccMinusBbb = Get-BpChanges $cccMinusBbb
    hyMinusIg   = Get-BpChanges $hyMinusIg
    bMinusBbb   = Get-BpChanges $bMinusBbb
}
foreach ($k in @("cccMinusBbb", "hyMinusIg", "bMinusBbb")) {
    $d = $dispersion[$k]
    $d.value = if ($null -ne $d.value) { [math]::Round($d.value, 0) } else { $null }
    $d.chg1w = if ($null -ne $d.chg1w) { [math]::Round($d.chg1w, 0) } else { $null }
    $d.chg1m = if ($null -ne $d.chg1m) { [math]::Round($d.chg1m, 0) } else { $null }
    $d.chg3m = if ($null -ne $d.chg3m) { [math]::Round($d.chg3m, 0) } else { $null }
}

Write-Output ("  CCC-BBB: {0}bp  HY-IG: {1}bp  B-BBB: {2}bp" -f $dispersion.cccMinusBbb.value, $dispersion.hyMinusIg.value, $dispersion.bMinusBbb.value)

# ===================== Write payload (atomic) =====================

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$lastObservation = ($raw.Values | Where-Object { $_.Count -gt 0 } | ForEach-Object { $_[$_.Count - 1].Date } | Sort-Object -Descending | Select-Object -First 1)

$payload = @{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = $nowUtc
    lastObservation       = $lastObservation
    sourceStatus          = $sourceStatus
    cards                 = $cards
    qualityCurve          = $qualityCurve
    dispersion            = $dispersion
    series                = @{
        ig          = To-SeriesJson $raw["ig"]
        bbb         = To-SeriesJson $raw["bbb"]
        bb          = To-SeriesJson $raw["bb"]
        b           = To-SeriesJson $raw["b"]
        ccc         = To-SeriesJson $raw["ccc"]
        hy          = To-SeriesJson $raw["hy"]
        cccMinusBbb = To-SeriesJson $cccMinusBbb
        hyMinusIg   = To-SeriesJson $hyMinusIg
        bMinusBbb   = To-SeriesJson $bMinusBbb
    }
}

Write-DataFileAtomic -Path $outPath -VarName "CREDIT_DATA" -Payload $payload -Depth 8

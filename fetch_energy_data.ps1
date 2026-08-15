# Physical oil/gas system: headline spot prices, locally-calculated crack spreads (badged as
# Heimdall calc, same convention as Net Liquidity), inventories, and natural gas storage.
# Source: EIA API v2 (api.eia.gov). Writes data\energy_data.js.
#
# Data-integrity model (see fetch_common.ps1): every raw series is validated and merged with its
# own existing cached history independently - a bad/blocked/malformed EIA fetch for one series
# falls back to that series' last known-good data without affecting the others.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
# Local dev: dot-source the gitignored config file. CI (GitHub Actions): fall back to the
# EIA_API_KEY env var, populated from a repo secret - the key is never written to disk there.
$eiaConfigPath = Join-Path $root "eia_config.ps1"
if (Test-Path $eiaConfigPath) {
    . $eiaConfigPath
} elseif ($env:EIA_API_KEY) {
    $EIA_API_KEY = $env:EIA_API_KEY
} else {
    throw "EIA_API_KEY not found - create eia_config.ps1 locally or set the EIA_API_KEY env var/secret in CI."
}

$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$outPath = Join-Path $dataDir "energy_data.js"

$existingPayload = Get-ExistingPayload $outPath
if ($existingPayload) { Write-Output ("Existing cache found: generated {0}" -f $existingPayload.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }
function Get-ExistingRaw($key) {
    if ($existingPayload -and $existingPayload.rawSeries -and $existingPayload.rawSeries.$key) {
        return ConvertFrom-SeriesJson $existingPayload.rawSeries.$key
    }
    return @()
}

$START_DATE = "2010-01-01"

# Never throws - a network/HTTP failure becomes an empty array, which Test-SeriesSane rejects
# and the per-series merge below then falls back to that series' cached history for.
function Get-EiaSeries($route, $seriesId, $frequency) {
    try {
        $uri = "https://api.eia.gov/v2/$route/data/?api_key=$EIA_API_KEY&frequency=$frequency&data%5B0%5D=value&facets%5Bseries%5D%5B%5D=$seriesId&sort%5B0%5D%5Bcolumn%5D=period&sort%5B0%5D%5Bdirection%5D=asc&length=5000&start=$START_DATE"
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($o in $resp.response.data) {
            if ($null -ne $o.value -and $o.value -ne "") {
                $out.Add([PSCustomObject]@{ Date = $o.period; Value = [double]$o.value })
            }
        }
        return $out | Sort-Object Date
    } catch {
        Write-Host ("::error::EIA fetch failed for {0}/{1}: {2}" -f $route, $seriesId, $_.Exception.Message)
        return @()
    }
}

function New-DateMap($series) {
    $m = @{}
    foreach ($p in $series) { $m[$p.Date] = $p.Value }
    return $m
}

function Get-Changes($series) {
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

    return @{ value = $latest.Value; asOfDate = $latest.Date; chg1d = $chg1d; chg1w = Find-LookbackChange 7; chg1m = Find-LookbackChange 30; chgYtd = $chgYtd }
}

function Round-Stat($stat, $digits, $freq) {
    $r = @{ asOfDate = $stat.asOfDate; freq = $freq }
    foreach ($k in @("value", "chg1d", "chg1w", "chg1m", "chgYtd")) {
        $v = $stat[$k]
        $r[$k] = if ($null -ne $v) { [math]::Round($v, $digits) } else { $null }
    }
    return $r
}

function To-SeriesJson($series, $digits) {
    return , $(foreach ($p in $series) { @{ d = $p.Date; v = [math]::Round($p.Value, $digits) } })
}

Write-Output "Fetching EIA series..."
# Conservative MinCount floors by native frequency (2010-now) - well under the realistic count.
$EIA_ROUTES = [ordered]@{
    WTI        = @{ route = "petroleum/pri/spt"; id = "RWTC"; freq = "daily"; minCount = 1000 }
    BRENT      = @{ route = "petroleum/pri/spt"; id = "RBRTE"; freq = "daily"; minCount = 1000 }
    RBOB       = @{ route = "petroleum/pri/spt"; id = "EER_EPMRR_PF4_Y05LA_DPG"; freq = "daily"; minCount = 1000 }
    ULSD       = @{ route = "petroleum/pri/spt"; id = "EER_EPD2DXL0_PF4_Y35NY_DPG"; freq = "daily"; minCount = 1000 }
    HENRYHUB   = @{ route = "natural-gas/pri/fut"; id = "RNGWHHD"; freq = "daily"; minCount = 1000 }
    CRUDESTK   = @{ route = "petroleum/stoc/wstk"; id = "WCRSTUS1"; freq = "weekly"; minCount = 300 }
    CUSHINGSTK = @{ route = "petroleum/stoc/wstk"; id = "W_EPC0_SAX_YCUOK_MBBL"; freq = "weekly"; minCount = 300 }
    GASSTK     = @{ route = "petroleum/stoc/wstk"; id = "WGTSTUS1"; freq = "weekly"; minCount = 300 }
    DISTSTK    = @{ route = "petroleum/stoc/wstk"; id = "WDISTUS1"; freq = "weekly"; minCount = 300 }
    UTIL       = @{ route = "petroleum/pnp/wiup"; id = "WPULEUS3"; freq = "weekly"; minCount = 300 }
    CRUDEPROD  = @{ route = "petroleum/crd/crpdn"; id = "MCRFPUS2"; freq = "monthly"; minCount = 80 }
    GASSTOR    = @{ route = "natural-gas/stor/wkly"; id = "NW2_EPG0_SWO_R48_BCF"; freq = "weekly"; minCount = 300 }
}
$raw = @{}
$sourceStatus = @{}
foreach ($k in $EIA_ROUTES.Keys) {
    $meta = $EIA_ROUTES[$k]
    $fresh = Get-EiaSeries $meta.route $meta.id $meta.freq
    $result = Get-ValidatedMergedSeries -Fresh $fresh -Existing (Get-ExistingRaw $k) -MinCount $meta.minCount -Name $k
    $raw[$k] = $result.series
    $sourceStatus[$k] = $result.status
    if ($raw[$k].Count -gt 0) {
        Write-Output ("  {0}: {1} points, latest {2} = {3} [{4}]" -f $k, $raw[$k].Count, $raw[$k][-1].Date, $raw[$k][-1].Value, $result.status)
    } else {
        Write-Output ("  {0}: NO DATA available [{1}]" -f $k, $result.status)
    }
}

# WTI/RBOB/ULSD feed crack spreads, GASSTOR feeds the 5Y-seasonal comparison - if these are
# completely unusable (fresh invalid AND no cache), those calc'd sections would be empty/wrong.
# Abort and preserve the whole existing file rather than publish a broken one.
$CRITICAL_KEYS = @("WTI", "RBOB", "ULSD", "GASSTOR")
$missingCritical = $CRITICAL_KEYS | Where-Object { $raw[$_].Count -eq 0 }
if ($missingCritical) {
    throw ("Critical series unusable (no fresh data and no cache): {0} - refusing to write data\energy_data.js." -f ($missingCritical -join ", "))
}

# --- Crack spreads (Heimdall calc): convert $/gal product prices to $/bbl (x42), date-matched to WTI ---
Write-Output "Computing crack spreads..."
$rbobMap = New-DateMap $raw["RBOB"]
$ulsdMap = New-DateMap $raw["ULSD"]

$crack321 = New-Object System.Collections.Generic.List[object]
$crackGasoline = New-Object System.Collections.Generic.List[object]
$crackDistillate = New-Object System.Collections.Generic.List[object]
foreach ($p in $raw["WTI"]) {
    if ($rbobMap.ContainsKey($p.Date) -and $ulsdMap.ContainsKey($p.Date)) {
        $gasBbl = $rbobMap[$p.Date] * 42.0
        $dieselBbl = $ulsdMap[$p.Date] * 42.0
        $crack321.Add([PSCustomObject]@{ Date = $p.Date; Value = ((2 * $gasBbl + $dieselBbl) - 3 * $p.Value) / 3.0 })
        $crackGasoline.Add([PSCustomObject]@{ Date = $p.Date; Value = $gasBbl - $p.Value })
        $crackDistillate.Add([PSCustomObject]@{ Date = $p.Date; Value = $dieselBbl - $p.Value })
    }
}
$crack321 = $crack321.ToArray()
$crackGasoline = $crackGasoline.ToArray()
$crackDistillate = $crackDistillate.ToArray()

# --- Natural gas storage vs 5-year seasonal average (same month/day window, prior 5 years) ---
$storageArr = $raw["GASSTOR"]
$latestStorage = $storageArr[$storageArr.Count - 1]
$latestDate = [DateTime]::Parse($latestStorage.Date)
$fiveYearVals = New-Object System.Collections.Generic.List[double]
for ($yr = 1; $yr -le 5; $yr++) {
    $targetDate = $latestDate.AddYears(-$yr)
    $best = $null
    $bestDiff = [double]::MaxValue
    foreach ($p in $storageArr) {
        $d = [DateTime]::Parse($p.Date)
        $diff = [math]::Abs(($d - $targetDate).TotalDays)
        if ($diff -lt $bestDiff -and $diff -le 10) { $bestDiff = $diff; $best = $p.Value }
    }
    if ($null -ne $best) { $fiveYearVals.Add($best) }
}
$storage5yAvg = $null
if ($fiveYearVals.Count -gt 0) {
    $sum = 0.0
    foreach ($v in $fiveYearVals) { $sum += $v }
    $storage5yAvg = $sum / $fiveYearVals.Count
}
$storageVs5y = $null
$storageVs5yPct = $null
if ($null -ne $storage5yAvg) {
    $storageVs5y = $latestStorage.Value - $storage5yAvg
    $storageVs5yPct = ($storageVs5y / $storage5yAvg) * 100.0
}

# --- Assemble payload ---
$prices = @{
    wti   = Round-Stat (Get-Changes $raw["WTI"]) 2 "daily"
    brent = Round-Stat (Get-Changes $raw["BRENT"]) 2 "daily"
    henryHub = Round-Stat (Get-Changes $raw["HENRYHUB"]) 3 "daily"
    rbob  = Round-Stat (Get-Changes $raw["RBOB"]) 3 "daily"
    ulsd  = Round-Stat (Get-Changes $raw["ULSD"]) 3 "daily"
}
$cracks = @{
    crack321 = Round-Stat (Get-Changes $crack321) 2 "daily"
    crackGasoline = Round-Stat (Get-Changes $crackGasoline) 2 "daily"
    crackDistillate = Round-Stat (Get-Changes $crackDistillate) 2 "daily"
}
$inventories = @{
    crudeStocks   = Round-Stat (Get-Changes $raw["CRUDESTK"]) 0 "weekly"
    cushingStocks = Round-Stat (Get-Changes $raw["CUSHINGSTK"]) 0 "weekly"
    gasolineStocks = Round-Stat (Get-Changes $raw["GASSTK"]) 0 "weekly"
    distillateStocks = Round-Stat (Get-Changes $raw["DISTSTK"]) 0 "weekly"
    refineryUtilization = Round-Stat (Get-Changes $raw["UTIL"]) 1 "weekly"
    crudeProduction = Round-Stat (Get-Changes $raw["CRUDEPROD"]) 0 "monthly"
}
$naturalGas = @{
    henryHub = $prices.henryHub
    workingGasStorage = Round-Stat (Get-Changes $raw["GASSTOR"]) 0 "weekly"
    storageVs5yAvg = @{
        value = if ($null -ne $storageVs5y) { [math]::Round($storageVs5y, 0) } else { $null }
        pct   = if ($null -ne $storageVs5yPct) { [math]::Round($storageVs5yPct, 1) } else { $null }
        avg   = if ($null -ne $storage5yAvg) { [math]::Round($storage5yAvg, 0) } else { $null }
        asOfDate = $latestStorage.Date
        freq = "weekly"
    }
}
$series = @{
    wti = To-SeriesJson $raw["WTI"] 2
    brent = To-SeriesJson $raw["BRENT"] 2
    henryHub = To-SeriesJson $raw["HENRYHUB"] 3
    crack321 = To-SeriesJson $crack321 2
    crackGasoline = To-SeriesJson $crackGasoline 2
    crackDistillate = To-SeriesJson $crackDistillate 2
    crudeStocks = To-SeriesJson $raw["CRUDESTK"] 0
    cushingStocks = To-SeriesJson $raw["CUSHINGSTK"] 0
    gasolineStocks = To-SeriesJson $raw["GASSTK"] 0
    distillateStocks = To-SeriesJson $raw["DISTSTK"] 0
    workingGasStorage = To-SeriesJson $raw["GASSTOR"] 0
}

$rawSeriesJson = @{}
foreach ($k in $EIA_ROUTES.Keys) { $rawSeriesJson[$k] = To-SeriesJson $raw[$k] 4 }

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$lastObservation = ($raw.Values | Where-Object { $_.Count -gt 0 } | ForEach-Object { $_[$_.Count - 1].Date } | Sort-Object -Descending | Select-Object -First 1)

$payload = @{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = $nowUtc
    lastObservation        = $lastObservation
    sourceStatus           = $sourceStatus
    prices = $prices
    cracks = $cracks
    inventories = $inventories
    naturalGas = $naturalGas
    series = $series
    rawSeries = $rawSeriesJson
}

Write-DataFileAtomic -Path $outPath -VarName "ENERGY_DATA" -Payload $payload -Depth 8
Write-Output ("Crack 3:2:1 = {0}  Gasoline crack = {1}  Distillate crack = {2}" -f $cracks.crack321.value, $cracks.crackGasoline.value, $cracks.crackDistillate.value)
Write-Output ("Storage vs 5Y avg: {0} Bcf ({1}%)" -f $naturalGas.storageVs5yAvg.value, $naturalGas.storageVs5yAvg.pct)

# Physical oil/gas system: headline spot prices, locally-calculated crack spreads (badged as
# Heimdall calc, same convention as Net Liquidity), inventories, and natural gas storage.
# Source: EIA API v2 (api.eia.gov). Writes data\energy_data.js.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "eia_config.ps1")

$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$START_DATE = "2010-01-01"

function Get-EiaSeries($route, $seriesId, $frequency) {
    $uri = "https://api.eia.gov/v2/$route/data/?api_key=$EIA_API_KEY&frequency=$frequency&data%5B0%5D=value&facets%5Bseries%5D%5B%5D=$seriesId&sort%5B0%5D%5Bcolumn%5D=period&sort%5B0%5D%5Bdirection%5D=asc&length=5000&start=$START_DATE"
    $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($o in $resp.response.data) {
        if ($null -ne $o.value -and $o.value -ne "") {
            $out.Add([PSCustomObject]@{ Date = $o.period; Value = [double]$o.value })
        }
    }
    return , ($out | Sort-Object Date)
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
$raw = @{}
$raw["WTI"]        = Get-EiaSeries "petroleum/pri/spt" "RWTC" "daily"
$raw["BRENT"]      = Get-EiaSeries "petroleum/pri/spt" "RBRTE" "daily"
$raw["RBOB"]       = Get-EiaSeries "petroleum/pri/spt" "EER_EPMRR_PF4_Y05LA_DPG" "daily"
$raw["ULSD"]       = Get-EiaSeries "petroleum/pri/spt" "EER_EPD2DXL0_PF4_Y35NY_DPG" "daily"
$raw["HENRYHUB"]   = Get-EiaSeries "natural-gas/pri/fut" "RNGWHHD" "daily"
$raw["CRUDESTK"]   = Get-EiaSeries "petroleum/stoc/wstk" "WCRSTUS1" "weekly"
$raw["CUSHINGSTK"] = Get-EiaSeries "petroleum/stoc/wstk" "W_EPC0_SAX_YCUOK_MBBL" "weekly"
$raw["GASSTK"]     = Get-EiaSeries "petroleum/stoc/wstk" "WGTSTUS1" "weekly"
$raw["DISTSTK"]    = Get-EiaSeries "petroleum/stoc/wstk" "WDISTUS1" "weekly"
$raw["UTIL"]       = Get-EiaSeries "petroleum/pnp/wiup" "WPULEUS3" "weekly"
$raw["CRUDEPROD"]  = Get-EiaSeries "petroleum/crd/crpdn" "MCRFPUS2" "monthly"
$raw["GASSTOR"]    = Get-EiaSeries "natural-gas/stor/wkly" "NW2_EPG0_SWO_R48_BCF" "weekly"

foreach ($k in $raw.Keys) {
    $s = $raw[$k]
    if ($s.Count -gt 0) { Write-Output ("  {0}: {1} points, latest {2} = {3}" -f $k, $s.Count, $s[-1].Date, $s[-1].Value) }
    else { Write-Output ("  {0}: no data" -f $k) }
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

$payload = @{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    prices = $prices
    cracks = $cracks
    inventories = $inventories
    naturalGas = $naturalGas
    series = $series
}

$json = $payload | ConvertTo-Json -Depth 8 -Compress
$jsOut = "window.ENERGY_DATA = $json;"
$outPath = Join-Path $dataDir "energy_data.js"
Set-Content -Path $outPath -Value $jsOut -Encoding UTF8

Write-Output "Wrote $outPath"
Write-Output ("Crack 3:2:1 = {0}  Gasoline crack = {1}  Distillate crack = {2}" -f $cracks.crack321.value, $cracks.crackGasoline.value, $cracks.crackDistillate.value)
Write-Output ("Storage vs 5Y avg: {0} Bcf ({1}%)" -f $naturalGas.storageVs5yAvg.value, $naturalGas.storageVs5yAvg.pct)

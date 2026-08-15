# Computes an estimated BTC options dealer gamma exposure (GEX) snapshot from Deribit's public
# options chain and writes data\gex_data.js.
#
# IMPORTANT - this is a modeled estimate, not an observed fact. No venue discloses actual dealer
# books. The standard public-data convention (used by SqueezeMetrics, SpotGamma, and every other
# free/public GEX calculator) assumes dealers are net long calls and net short puts - i.e. the
# opposite side of the typical "sell covered calls, buy protective puts" customer flow - and
# derives per-instrument gamma from Black-Scholes using each option's own mark IV. Net GEX =
# (call gamma x call OI) - (put gamma x put OI), scaled to a dollar-per-1%-move figure. Treat
# this as Heimdall's own calculated estimate (same "calc" disclosure as the Net Liquidity Proxy
# on the Fed tab), never as verified dealer positioning.
#
# This is a live cross-sectional snapshot (the full options chain at fetch time), not a
# mergeable time series - there's nothing to "merge by date" the way a price history works. On a
# failed/invalid fetch, the correct fail-stale behavior is simply to leave the existing cached
# snapshot file untouched (same treatment as CME basis in fetch_btc_data.ps1), not to write a
# degenerate partial payload.

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$outPath = Join-Path $dataDir "gex_data.js"

Write-Output "Fetching BTC options chain from Deribit..."
$chain = $null
try {
    $resp = Invoke-RestMethod -Uri "https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=option" -TimeoutSec 30
    $chain = $resp.result
} catch {
    Write-Host ("::error::Deribit fetch failed: {0}" -f $_.Exception.Message)
}

# A healthy BTC options chain on Deribit runs several hundred listed instruments. Well under
# that means a truncated/malformed response, not a quiet market - don't trust it.
if (-not $chain -or $chain.Count -lt 200) {
    Write-Host ("::warning::Deribit chain missing or too small ({0} instruments) - leaving existing gex_data.js untouched" -f ($(if ($chain) { $chain.Count } else { 0 })))
    if (-not (Test-Path $outPath)) {
        throw "No usable Deribit options data and no existing cache - refusing to write data\gex_data.js."
    }
    exit 0
}

function Get-NormPdf($x) { return (1.0 / [math]::Sqrt(2 * [math]::PI)) * [math]::Exp(-0.5 * $x * $x) }

$monthMap = @{ JAN=1;FEB=2;MAR=3;APR=4;MAY=5;JUN=6;JUL=7;AUG=8;SEP=9;OCT=10;NOV=11;DEC=12 }
$nowUtc = (Get-Date).ToUniversalTime()

$spot = $null
$byStrike = [ordered]@{}
$totalCallOI = 0.0
$totalPutOI = 0.0
$netGex = 0.0
$usedCount = 0

foreach ($inst in $chain) {
    $oi = [double]$inst.open_interest
    if ($oi -le 0) { continue }
    if ($null -eq $inst.mark_iv -or [double]$inst.mark_iv -le 0) { continue }
    if ($null -eq $inst.underlying_price -or [double]$inst.underlying_price -le 0) { continue }
    if ($inst.instrument_name -notmatch '^BTC-(\d{1,2})([A-Z]{3})(\d{2})-(\d+(?:\.\d+)?)-(C|P)$') { continue }

    $mon = $monthMap[$Matches[2]]
    if (-not $mon) { continue }
    $day = [int]$Matches[1]
    $yr = 2000 + [int]$Matches[3]
    $strike = [double]$Matches[4]
    $type = $Matches[5]

    # Deribit options expire 08:00 UTC on the listed date.
    $expiry = [DateTime]::new($yr, $mon, $day, 8, 0, 0, [DateTimeKind]::Utc)
    $T = ($expiry - $nowUtc).TotalDays / 365.25
    if ($T -le 0) { continue }

    $S = [double]$inst.underlying_price
    if ($null -eq $spot) { $spot = $S }
    $sigma = [double]$inst.mark_iv / 100.0
    if ($sigma -le 0) { continue }

    # Black-Scholes gamma, r=0 (standard simplification for crypto options - carry cost is
    # negligible next to BTC's own volatility, and Deribit's own interest_rate field is 0 here).
    $d1 = ([math]::Log($S / $strike) + (0.5 * $sigma * $sigma) * $T) / ($sigma * [math]::Sqrt($T))
    $gamma = (Get-NormPdf $d1) / ($S * $sigma * [math]::Sqrt($T))

    # Dollar gamma exposure per 1% move. Contract multiplier is 1 for Deribit BTC options (1
    # contract = 1 BTC, confirmed against Deribit's own contract spec - not assumed from the
    # field name).
    $dollarGex = $gamma * $oi * $S * $S * 0.01
    $usedCount++

    $strikeKey = "{0:F0}" -f $strike
    if (-not $byStrike.Contains($strikeKey)) {
        $byStrike[$strikeKey] = [PSCustomObject]@{ Strike = $strike; CallGex = 0.0; PutGex = 0.0 }
    }

    if ($type -eq "C") {
        $totalCallOI += $oi
        $netGex += $dollarGex
        $byStrike[$strikeKey].CallGex += $dollarGex
    } else {
        $totalPutOI += $oi
        $netGex -= $dollarGex
        $byStrike[$strikeKey].PutGex += $dollarGex
    }
}

if ($usedCount -lt 20 -or $null -eq $spot) {
    Write-Host ("::warning::Only {0} instruments produced a usable gamma figure - leaving existing gex_data.js untouched" -f $usedCount)
    if (-not (Test-Path $outPath)) {
        throw "Deribit chain fetched but produced no usable gamma data, and no existing cache - refusing to write data\gex_data.js."
    }
    exit 0
}

$byStrikeSorted = $byStrike.Values | Sort-Object Strike | ForEach-Object {
    @{ k = $_.Strike; net = [math]::Round($_.CallGex - $_.PutGex, 0) }
}

$putCallOiRatio = $null
if ($totalCallOI -gt 0) { $putCallOiRatio = [math]::Round($totalPutOI / $totalCallOI, 3) }

$nowUtcStr = $nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
$payload = @{
    generatedAtUtc        = $nowUtcStr
    lastSuccessfulRefresh = $nowUtcStr
    asOfUtc               = $nowUtcStr
    sourceStatus           = @{ deribit = "ok" }
    spot                   = [math]::Round($spot, 2)
    netGexUsd              = [math]::Round($netGex, 0)
    totalCallOiBtc         = [math]::Round($totalCallOI, 2)
    totalPutOiBtc          = [math]::Round($totalPutOI, 2)
    putCallOiRatio         = $putCallOiRatio
    instrumentsUsed        = $usedCount
    byStrike               = $byStrikeSorted
}

Write-DataFileAtomic -Path $outPath -VarName "GEX_DATA" -Payload $payload -Depth 6
Write-Output ("Spot: {0}  Net GEX: {1:N0}  Call OI: {2} BTC  Put OI: {3} BTC  P/C ratio: {4}  instruments used: {5}" -f `
    $spot, $netGex, [math]::Round($totalCallOI, 1), [math]::Round($totalPutOI, 1), $putCallOiRatio, $usedCount)

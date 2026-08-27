# Pulls live-ish quotes + full daily price history for a fixed watchlist of equities from
# Yahoo Finance's public chart API (same unofficial endpoint already used for DXY/CME BTC
# futures/ZQ Fed Funds futures elsewhere in this project - no key needed). Writes
# data\equities_data.js.
#
# Two groups on the Equities tab:
#   - Bitcoin proxies: MSTR (Strategy common) + Strategy's full preferred stack - STRK (8.00%
#     Series A Perpetual Strike), STRF (10.00% Series A Perpetual Strife), STRD (10.00% Series A
#     Perpetual Stride), STRC (variable-rate monthly, added 2026-08-20; the other three added
#     2026-08-25). Confirmed all four are real distinct listings via Yahoo before adding -
#     tickers this close in name/structure are exactly the kind of thing not to guess at.
#   - AI hyperscalers: NVDA, MSFT, GOOGL, AMZN, META, ORCL (same five+one already tracked for
#     capex/revenue on the AI tab via SEC EDGAR - this adds their actual stock price alongside
#     those fundamentals)
#
# NOTE on source quality (see HEIMDALL_SKILL.md / conventions memory on data-source hierarchy):
# this is an unofficial, undocumented endpoint - fine for a personal informational dashboard,
# not something to build commercial/redistributed use on. Real firms use licensed data
# (Bloomberg/Refinitiv/ICE) for exactly that reason - contractual usage rights, SLAs, audit
# trail. Explicitly not a live tick feed; "regularMarketPrice" is Yahoo's own consolidated
# quote. Runs on its own Equities Fast workflow (refresh-equities-fast.yml, 15-min cadence,
# 4am-8pm ET weekdays covering pre-market/regular/after-hours), split out from Market Fast on
# 2026-08-20 so this could refresh faster than the FRED-bundled series it used to share a
# schedule with.
#
# Each ticker is validated and merged independently (source isolation) - one bad/blocked ticker
# never blocks the other seven. "range=max" was tested and found unreliable for at least one
# ticker (MSTR: returned only 339 points vs 2512 for an explicit 10y, apparently some Yahoo-side
# quirk) - using an explicit long range instead, confirmed to correctly return the full ~28-year
# history for MSTR (the oldest-listed name here, since 1998).

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$outPath = Join-Path $dataDir "equities_data.js"

$existingPayload = Get-ExistingPayload $outPath
if ($existingPayload) { Write-Output ("Existing cache found: generated {0}" -f $existingPayload.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }

function Get-ExistingSeries($ticker) {
    if ($existingPayload -and $existingPayload.tickers -and $existingPayload.tickers.$ticker -and $existingPayload.tickers.$ticker.series) {
        return , ($existingPayload.tickers.$ticker.series | ForEach-Object { [PSCustomObject]@{ Date = $_.d; Value = [double]$_.c } })
    }
    return @()
}

$WATCHLIST = @(
    @{ Ticker = "MSTR";  Group = "btc-proxy" },
    @{ Ticker = "STRK";  Group = "btc-proxy" },
    @{ Ticker = "STRF";  Group = "btc-proxy" },
    @{ Ticker = "STRD";  Group = "btc-proxy" },
    @{ Ticker = "STRC";  Group = "btc-proxy" },
    @{ Ticker = "NVDA";  Group = "hyperscaler" },
    @{ Ticker = "MSFT";  Group = "hyperscaler" },
    @{ Ticker = "GOOGL"; Group = "hyperscaler" },
    @{ Ticker = "AMZN";  Group = "hyperscaler" },
    @{ Ticker = "META";  Group = "hyperscaler" },
    @{ Ticker = "ORCL";  Group = "hyperscaler" }
)

$tickersOut = [ordered]@{}
$sourceStatus = [ordered]@{}
$ua = "Mozilla/5.0"

foreach ($w in $WATCHLIST) {
    $sym = $w.Ticker
    Write-Output ("Fetching {0}..." -f $sym)
    $freshSeries = @()
    $meta = $null
    try {
        $resp = Invoke-RestMethod -Uri "https://query1.finance.yahoo.com/v8/finance/chart/${sym}?range=30y&interval=1d" -Headers @{ "User-Agent" = $ua } -TimeoutSec 30
        $result = $resp.chart.result[0]
        $meta = $result.meta
        $timestamps = $result.timestamp
        $closes = $result.indicators.quote[0].close
        if ($timestamps -and $closes -and $timestamps.Count -eq $closes.Count) {
            $list = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt $timestamps.Count; $i++) {
                $c = $closes[$i]
                if ($null -eq $c) { continue }
                $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$timestamps[$i]).UtcDateTime.Date
                $list.Add([PSCustomObject]@{ Date = $d.ToString("yyyy-MM-dd"); Value = [double]$c })
            }
            $freshSeries = $list | Sort-Object Date
        }
    } catch {
        Write-Host ("::warning::{0} fetch failed: {1}" -f $sym, $_.Exception.Message)
    }

    $existingSeries = Get-ExistingSeries $sym
    # Strategy's preferreds are all recent listings (STRC/STRK/STRF/STRD, 2024-2025) - a short
    # real history is expected, not a truncation. 30 is a
    # conservative floor that still catches a genuinely broken/empty response.
    $seriesResult = Get-ValidatedMergedSeries -Fresh $freshSeries -Existing $existingSeries -MinCount 30 -Name $sym
    $sourceStatus[$sym] = $seriesResult.status

    if ($seriesResult.series.Count -eq 0) {
        Write-Host ("::error::{0}: no usable price data (fresh fetch invalid and no existing cache) - omitting from this refresh" -f $sym)
        continue
    }

    $price = $null
    $prevClose = $null
    $chgPct = $null
    $wk52Hi = $null
    $wk52Lo = $null
    $shortName = $sym
    if ($meta -and $null -ne $meta.regularMarketPrice) {
        $price = [double]$meta.regularMarketPrice
        # NOT meta.chartPreviousClose - confirmed live that field reflects the close immediately
        # before the *requested range window* (e.g. ~30 years ago at range=30y, not yesterday),
        # despite its name. A same-session test showed NVDA's chartPreviousClose as $0.044 at
        # range=30y vs the real $224.09 at range=5d - a >494,000% "change" bug caught before
        # shipping. Use the second-to-last point of our own fetched daily series instead, which
        # is self-consistent regardless of range and doesn't depend on this field's odd semantics.
        if ($seriesResult.series.Count -ge 2) {
            $prevClose = $seriesResult.series[-2].Value
            if ($prevClose -gt 0) { $chgPct = (($price - $prevClose) / $prevClose) * 100.0 }
        }
        if ($null -ne $meta.fiftyTwoWeekHigh) { $wk52Hi = [double]$meta.fiftyTwoWeekHigh }
        if ($null -ne $meta.fiftyTwoWeekLow) { $wk52Lo = [double]$meta.fiftyTwoWeekLow }
        if ($meta.shortName) { $shortName = $meta.shortName }
    } elseif ($existingPayload -and $existingPayload.tickers -and $existingPayload.tickers.$sym) {
        # Live quote fetch failed but the price history validated (e.g. from cache) - fall back
        # to the last cached quote fields too, rather than showing a blank price next to a
        # perfectly good chart.
        $e = $existingPayload.tickers.$sym
        $price = $e.price; $prevClose = $e.prevClose; $chgPct = $e.chgPct
        $wk52Hi = $e.wk52Hi; $wk52Lo = $e.wk52Lo; $shortName = $e.shortName
    }

    # Pre/post-market: Yahoo's meta only populates preMarketPrice/postMarketPrice while the
    # market is actually in that session (marketState "PRE"/"POST") - outside those windows
    # (including during regular hours) these fields are simply absent, which is the correct
    # fail-stale behavior here, not a bug to work around. Deliberately kept as a distinct field
    # rather than blended into `price` - extended-hours prints are thin-volume/wide-spread and
    # shouldn't be presented with the same weight as a regular-session quote.
    $extHours = $null
    if ($meta -and $meta.marketState -eq "PRE" -and $null -ne $meta.preMarketPrice) {
        $extHours = @{
            session = "pre"
            price   = [math]::Round([double]$meta.preMarketPrice, 2)
            chgPct  = if ($null -ne $meta.preMarketChangePercent) { [math]::Round([double]$meta.preMarketChangePercent, 2) } else { $null }
            asOfUtc = if ($null -ne $meta.preMarketTime) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$meta.preMarketTime).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $null }
        }
    } elseif ($meta -and $meta.marketState -eq "POST" -and $null -ne $meta.postMarketPrice) {
        $extHours = @{
            session = "post"
            price   = [math]::Round([double]$meta.postMarketPrice, 2)
            chgPct  = if ($null -ne $meta.postMarketChangePercent) { [math]::Round([double]$meta.postMarketChangePercent, 2) } else { $null }
            asOfUtc = if ($null -ne $meta.postMarketTime) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$meta.postMarketTime).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $null }
        }
    }

    $series = $seriesResult.series | ForEach-Object { @{ d = $_.Date; c = [math]::Round($_.Value, 4) } }

    $tickersOut[$sym] = @{
        name      = $shortName
        group     = $w.Group
        price     = if ($null -ne $price) { [math]::Round($price, 2) } else { $null }
        prevClose = if ($null -ne $prevClose) { [math]::Round($prevClose, 2) } else { $null }
        chgPct    = if ($null -ne $chgPct) { [math]::Round($chgPct, 2) } else { $null }
        wk52Hi    = if ($null -ne $wk52Hi) { [math]::Round($wk52Hi, 2) } else { $null }
        wk52Lo    = if ($null -ne $wk52Lo) { [math]::Round($wk52Lo, 2) } else { $null }
        extHours  = $extHours
        asOfDate  = $seriesResult.series[-1].Date
        series    = $series
    }
    Write-Output ("  {0}: {1} pts, price {2}, chg {3}% [{4}]" -f $sym, $series.Count, $tickersOut[$sym].price, $tickersOut[$sym].chgPct, $seriesResult.status)
}

if ($tickersOut.Count -eq 0) {
    throw "No tickers produced usable data this run - refusing to write data\equities_data.js."
}

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$payload = @{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = $nowUtc
    sourceStatus          = $sourceStatus
    tickers                = $tickersOut
}

Write-DataFileAtomic -Path $outPath -VarName "EQUITIES_DATA" -Payload $payload -Depth 8

# Builds a daily-accumulating single-name CDS conventional-spread history for the six AI
# hyperscalers plus CoreWeave (the levered neocloud end of the same buildout), Broadcom (the
# custom-accelerator and networking supplier to it) and Equinix (the data-center landlord), from
# two real
# free sources chained together:
#   1. ICE's public daily settlement price API (ICE Clear Credit / "icc-single-names") -
#      genuinely free, no key, confirmed via direct curl (not Cloudflare-gated like the
#      consumer-facing FINRA bond page or ICE Trade Vault ticker were).
#   2. The official ISDA CDS Standard Model converter, built and hosted by IHS Markit in
#      collaboration with S&P Global (cds.ihsmarkit.com/converter/convert) - the actual
#      production model, not a homemade approximation. Verified live against real Oracle data
#      before this script was written: ICE clean price 95.4226% -> converter output 211.9995bp,
#      consistent with independently-reported news figures for Oracle's CDS (~198-212bp same
#      period). Confirmed callable headlessly via plain curl/Invoke-RestMethod, no browser/auth
#      needed.
#
# Writes data\cds_data.js. History accumulates one point per ticker per trading day going
# forward - ICE's API only exposes each day's current settlement, not a historical archive, so
# (like several other Heimdall-calculated series) there's no backfill; it starts building from
# whenever this script first runs successfully.
#
# Contract rolls: the tracked instrument is the on-the-run 5Y (SNRFOR / USD / XR14, at each
# name's standard fixed coupon - see $COUPON_BP), whose maturity steps forward six months every March 20 and September 20. A spread on
# the new contract is not comparable to the old one (longer maturity = wider, all else equal -
# the 2026-09-21 roll from Jun-2031 to Dec-2031 stepped every name up ~7% in one day). Each
# history point therefore carries its own contract maturity ("m"), so the front end can mark and
# break the series at a roll instead of drawing the step as credit widening. The two contracts
# are deliberately NOT spliced into one adjusted series - every stored number stays an
# ICE-settled, ISDA-converted print.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$outPath = Join-Path $dataDir "cds_data.js"

$existingPayload = Get-ExistingPayload $outPath
if ($existingPayload) { Write-Output ("Existing cache found: generated {0}" -f $existingPayload.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }

function Get-ExistingSeries($ticker) {
    if ($existingPayload -and $existingPayload.tickers -and $existingPayload.tickers.$ticker -and $existingPayload.tickers.$ticker.series) {
        return , ($existingPayload.tickers.$ticker.series | ForEach-Object { [PSCustomObject]@{ Date = $_.d; Value = [double]$_.v } })
    }
    return @()
}

# date -> contract maturity for points already in the cache. Kept beside the {Date;Value}
# working series rather than inside it because Merge-SeriesByDate only carries those two fields.
function Get-ExistingMaturityMap($ticker) {
    $map = @{}
    if ($existingPayload -and $existingPayload.tickers -and $existingPayload.tickers.$ticker -and $existingPayload.tickers.$ticker.series) {
        foreach ($p in $existingPayload.tickers.$ticker.series) {
            if ($p.d -and $p.m) { $map[$p.d] = $p.m }
        }
    }
    return $map
}

# Maturity of the on-the-run 5Y single-name contract for a given clearing date, per the standard
# semi-annual roll: from Mar 20 the 5Y is Jun 20 five years on, from Sep 20 it is Dec 20 five
# years on (before Mar 20 it is still the prior September's contract).
function Get-OnTheRunMaturity([string]$clearingDate) {
    $d = [DateTime]::ParseExact($clearingDate, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    $mar20 = Get-Date -Year $d.Year -Month 3 -Day 20 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    $sep20 = Get-Date -Year $d.Year -Month 9 -Day 20 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    if ($d -ge $sep20) { return ("{0}-12-20" -f ($d.Year + 5)) }
    if ($d -ge $mar20) { return ("{0}-06-20" -f ($d.Year + 5)) }
    return ("{0}-12-20" -f ($d.Year + 4))
}

# ICE's own "name" strings are idiosyncratic (typos included, e.g. "Oracle Cop") - matched
# explicitly rather than guessed, so a future ICE-side rename doesn't silently drop a ticker.
$NAME_MAP = @{
    "Oracle Cop"         = "ORCL"
    "NVIDIA Corp"        = "NVDA"
    "Microsoft Corp"     = "MSFT"
    "Alphabet Inc"       = "GOOGL"
    "Amazon Com Inc"     = "AMZN"
    "META PLATFORMS INC" = "META"
    "COREWEAVE INC"      = "CRWV"
    "BROADCOM INC"       = "AVGO"
    "Equinix Inc"        = "EQIX"
}

# Standard fixed coupon of the contract tracked for each name: 100bp for the investment-grade
# names, 500bp for CoreWeave (high yield - the only contract ICE clears for it). The conventional
# spread the converter returns is comparable across coupons; the clean price is not. Verified
# before adding: CoreWeave's 2026-10-12 clean price 86.9294% at a 500bp coupon converts to
# 898.99bp, in line with independently-reported levels (~855bp in late July 2026).
$DEFAULT_COUPON_BP = "100"
$COUPON_BP = @{ CRWV = "500" }

Write-Output "Fetching ICE CDS settlement prices..."
$iceRecords = $null
try {
    $iceRecords = Invoke-RestMethod -Uri "https://www.ice.com/api/cds-settlement-prices/icc-single-names" -Headers @{ "User-Agent" = "Mozilla/5.0" } -TimeoutSec 30
} catch {
    Write-Host ("::error::ICE settlement price fetch failed: {0}" -f $_.Exception.Message)
}

if (-not $iceRecords -or $iceRecords.Count -lt 100) {
    Write-Host ("::warning::ICE response missing or too small ({0} records) - leaving existing cds_data.js untouched" -f ($(if ($iceRecords) { $iceRecords.Count } else { 0 })))
    if (-not (Test-Path $outPath)) {
        throw "No usable ICE data and no existing cache - refusing to write data\cds_data.js."
    }
    exit 0
}

$tickersOut = [ordered]@{}
$sourceStatus = [ordered]@{}

foreach ($name in $NAME_MAP.Keys) {
    $ticker = $NAME_MAP[$name]
    $trackedCoupon = if ($COUPON_BP.ContainsKey($ticker)) { $COUPON_BP[$ticker] } else { $DEFAULT_COUPON_BP }
    # instrumentName e.g. "ORCLE.SNRFOR.USD.XR14.100.2031-06-20" - tier, currency, doc clause,
    # coupon (bp) and maturity are the last five dot-delimited fields. ICE can list several
    # contracts for one name (other names carry up to 10), so the tracked one is selected
    # explicitly - senior unsecured / USD / XR14 / this name's standard coupon, on-the-run 5Y maturity - never
    # by whatever order ICE happens to return records in.
    $candidates = @()
    foreach ($r in $iceRecords) {
        if ($r.name -ne $name) { continue }
        $p = "$($r.instrumentName)" -split "\."
        if ($p.Count -lt 6) { continue }
        if ($p[-5] -ne "SNRFOR" -or $p[-4] -ne "USD" -or $p[-3] -ne "XR14" -or $p[-2] -ne $trackedCoupon) { continue }
        if ($p[-1] -notmatch '^\d{4}-\d{2}-\d{2}$' -or "$($r.clearingDate)" -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
        $candidates += $r
    }
    if ($candidates.Count -eq 0) {
        Write-Host ("::warning::{0} ({1}): no SNRFOR/USD/XR14/{2}bp contract in today's ICE record set - skipping this run" -f $ticker, $name, $trackedCoupon)
        $sourceStatus[$ticker] = "error"
        continue
    }

    $rec = $null
    $bestGapDays = $null
    foreach ($r in $candidates) {
        $mat = ("$($r.instrumentName)" -split "\.")[-1]
        $expected = Get-OnTheRunMaturity $r.clearingDate
        $gapDays = [math]::Abs(([DateTime]$mat - [DateTime]$expected).TotalDays)
        if ($null -eq $bestGapDays -or $gapDays -lt $bestGapDays) { $rec = $r; $bestGapDays = $gapDays }
    }
    $parts = $rec.instrumentName -split "\."
    $maturityDate = $parts[-1]
    $coupon = $parts[-2]
    $clearingDate = $rec.clearingDate
    if ($bestGapDays -gt 0) {
        Write-Host ("::warning::{0}: on-the-run maturity {1} not listed by ICE - tracking nearest listed contract {2}" -f $ticker, (Get-OnTheRunMaturity $clearingDate), $maturityDate)
    }
    $eodPrice = [double]$rec.eodPrice
    if ($eodPrice -le 0 -or $eodPrice -gt 300) {
        Write-Host ("::warning::{0}: implausible eodPrice {1} - skipping" -f $ticker, $eodPrice)
        $sourceStatus[$ticker] = "error"
        continue
    }
    $upfront = [math]::Round(100.0 - $eodPrice, 6)

    Write-Output ("{0}: ICE clean price {1} (matures {2}, {3}bp coupon) -> converting..." -f $ticker, $eodPrice, $maturityDate, $coupon)

    $spreadBp = $null
    try {
        $body = @{
            tradeDate       = $clearingDate
            maturityDate    = $maturityDate
            recovery        = "40"
            runningcoupon   = $coupon
            notional        = "1"
            currency        = "USD"
            cashSettleDays  = 3
            clientName      = "MarkitWeb"
            legacy          = $false
            holidayCode     = @("NYM")
            upfront         = "$upfront"
        } | ConvertTo-Json

        $result = Invoke-RestMethod -Uri "https://cds.ihsmarkit.com/converter/convert" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
        if ($null -ne $result.conventionalSpread) {
            $spreadBp = [double]$result.conventionalSpread
        }
    } catch {
        Write-Host ("::warning::{0}: ISDA converter call failed: {1}" -f $ticker, $_.Exception.Message)
    }

    if ($null -eq $spreadBp -or $spreadBp -le 0 -or $spreadBp -gt 100000) {
        Write-Host ("::warning::{0}: no usable conventional spread this run" -f $ticker)
        $sourceStatus[$ticker] = "error"
        continue
    }

    $freshSeries = @([PSCustomObject]@{ Date = $clearingDate; Value = $spreadBp })
    $existingSeries = Get-ExistingSeries $ticker
    # MinCount 1 - this is a daily-accumulating series that starts from nothing; the point is
    # never to reject a single fresh, valid observation, only to catch a truly empty/garbage one.
    $seriesResult = Get-ValidatedMergedSeries -Fresh $freshSeries -Existing $existingSeries -MinCount 1 -Name $ticker
    $sourceStatus[$ticker] = $seriesResult.status

    # @(...) forces array typing even when there's exactly one point - PowerShell otherwise
    # unwraps a single-item pipeline result to a bare scalar/hashtable, which would then
    # serialize as {d,v} instead of [{d,v}] and break every front-end consumer expecting an array.
    # Each point keeps the maturity of the contract it was settled on: today's point gets today's
    # contract, older points keep whatever they were stored with. A point with no recorded
    # maturity stays untagged (unknown) rather than being assumed to match today's contract.
    $maturityByDate = Get-ExistingMaturityMap $ticker
    if ($seriesResult.status -eq "ok") { $maturityByDate[$clearingDate] = $maturityDate }
    $series = @($seriesResult.series | ForEach-Object {
        $pt = [ordered]@{ d = $_.Date; v = [math]::Round($_.Value, 2) }
        if ($maturityByDate.ContainsKey($_.Date)) { $pt.m = $maturityByDate[$_.Date] }
        $pt
    })
    $tickersOut[$ticker] = @{
        name          = $rec.name
        maturityDate  = $maturityDate
        couponBp      = [double]$coupon
        cleanPrice    = $eodPrice
        spreadBp      = [math]::Round($spreadBp, 2)
        asOfDate      = $clearingDate
        series        = $series
    }
    Write-Output ("  {0}: {1} bp [{2}]" -f $ticker, $tickersOut[$ticker].spreadBp, $seriesResult.status)
}

if ($tickersOut.Count -eq 0) {
    throw "No tickers produced usable data this run - refusing to write data\cds_data.js."
}

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$payload = @{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = $nowUtc
    sourceStatus          = $sourceStatus
    tickers                = $tickersOut
}

Write-DataFileAtomic -Path $outPath -VarName "CDS_DATA" -Payload $payload -Depth 8

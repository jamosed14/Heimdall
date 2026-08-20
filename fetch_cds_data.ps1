# Builds a daily-accumulating single-name CDS conventional-spread history for the six AI
# hyperscalers, from two real free sources chained together:
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

# ICE's own "name" strings are idiosyncratic (typos included, e.g. "Oracle Cop") - matched
# explicitly rather than guessed, so a future ICE-side rename doesn't silently drop a ticker.
$NAME_MAP = @{
    "Oracle Cop"         = "ORCL"
    "NVIDIA Corp"        = "NVDA"
    "Microsoft Corp"     = "MSFT"
    "Alphabet Inc"       = "GOOGL"
    "Amazon Com Inc"     = "AMZN"
    "META PLATFORMS INC" = "META"
}

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
    $rec = $iceRecords | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $rec) {
        Write-Host ("::warning::{0} ({1}): not found in today's ICE record set - skipping this run" -f $ticker, $name)
        $sourceStatus[$ticker] = "error"
        continue
    }

    # instrumentName e.g. "ORCLE.SNRFOR.USD.XR14.100.2031-06-20" - coupon and maturity are the
    # last two dot-delimited fields.
    $parts = $rec.instrumentName -split "\."
    if ($parts.Count -lt 2) {
        Write-Host ("::warning::{0}: unparseable instrumentName '{1}' - skipping" -f $ticker, $rec.instrumentName)
        $sourceStatus[$ticker] = "error"
        continue
    }
    $maturityDate = $parts[-1]
    $coupon = $parts[-2]
    $clearingDate = $rec.clearingDate
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
    $series = @($seriesResult.series | ForEach-Object { @{ d = $_.Date; v = [math]::Round($_.Value, 2) } })
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

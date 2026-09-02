# Global Sovereign 10Y panel (Rates tab). No single free aggregator covers this - each
# country's own central bank/debt-management office publishes its own benchmark 10Y yield for
# free, and each does it in a genuinely different format. Deliberately a separate script from
# fetch_macro_data.ps1 rather than folded in: five heterogeneous sources (FRED JSON, a plain
# CSV, an SDMX API, an Excel workbook, a REST API, another CSV) belong isolated per the
# project's source-isolation rule, not threaded into the existing well-tested FRED/Yahoo
# pipeline. Writes data\global_rates_data.js.
#
# Trading Economics was considered first (single API, all countries/maturities in one call) but
# its guest/free tier is fully discontinued as of this build (confirmed live: "We are sorry, but
# the guest account has been discontinued... subscribe to a plan") - paid-only now, and this
# project doesn't introduce paid services without an explicit, deliberate call. FRED's own
# OECD-sourced series for these countries (IRLTLT01xxM156N) were also considered and rejected -
# confirmed live they're monthly with a ~2-3 month publish lag, which would silently contaminate
# an otherwise-live panel with data too stale to answer "why did JGBs move this morning."
#
# Sources (all free, no key, each verified live before writing this script):
#   US:        FRED DGS10 - same series already used elsewhere on Heimdall.
#   Japan:     Ministry of Finance JGB yield CSV - historical archive (back to 1974) + current-
#              month file, merged. Genuinely daily, official.
#   Germany:   Bundesbank SDMX API. Series key BBSIS/D.I.ZST.ZI.EUR.S1311.B.A604.R10XX.R.A.A._Z._Z.A -
#              LOWER CONFIDENCE than the other four. No human-readable series title was
#              findable (Bundesbank's metadata/search endpoints all 404'd); this key was
#              identified by decoding its own dimension codes (ISSUER_CLASS=S1311 -> ESA2010
#              "central government," ITEM=ZST -> yield curve, MATURITY=R10XX -> 10-year residual
#              maturity) and cross-checked against plausible Bund yield levels (~3.3-3.45%,
#              consistent with the concurrent global duration selloff), not confirmed via a
#              documented series ID. Worth a spot-check against a news-reported Bund yield if
#              this ever looks visibly wrong.
#   UK:        Bank of England "Government Liability Curve" nominal spot curve - published as a
#              daily-updated Excel workbook (OOXML), not CSV. Sheet "4. spot curve" (internal
#              file worksheets/sheet5.xml, confirmed via workbook.xml/rels), maturities run in
#              0.5-year steps starting column B=0.5Y - column U lands on exactly 10.0Y. Parsed
#              by unzipping the xlsx (it's a zip) and regexing the raw sheet XML directly - no
#              Excel-parsing module dependency. Pulls the small "latest" (current-month) file
#              every run plus the bounded "2025 to present" archive file (~1.5MB) for real
#              history, NOT the full 8-file/42MB 1979-present archive - that's a one-time-backfill
#              size, not a daily-refetch size.
#   Canada:    Bank of Canada Valet API, series BD.CDN.10YR.DQ.YLD - clean documented REST API.
#   Australia: RBA statistical table F2 (capital market yields) - daily CSV, real history to 2013.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
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
$outPath = Join-Path $dataDir "global_rates_data.js"

$existingPayload = Get-ExistingPayload $outPath
if ($existingPayload) { Write-Output ("Existing cache found: generated {0}" -f $existingPayload.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }

function Get-ExistingSeries($key) {
    if ($existingPayload -and $existingPayload.series -and $existingPayload.series.$key) {
        return ConvertFrom-SeriesJson $existingPayload.series.$key
    }
    return @()
}

$UA = @{ "User-Agent" = "Heimdall Catallaxy (personal research dashboard) jamosed14@gmail.com" }

# ---------- US: FRED DGS10 ----------
function Get-UsSeries() {
    try {
        $uri = "https://api.stlouisfed.org/fred/series/observations?series_id=DGS10&api_key=$FRED_API_KEY&file_type=json&observation_start=2000-01-01"
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($o in $resp.observations) {
            if ($o.value -ne ".") { $out.Add([PSCustomObject]@{ Date = $o.date; Value = [double]$o.value }) }
        }
        return , ($out | Sort-Object Date)
    } catch {
        Write-Host ("::error::US (FRED DGS10) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

# ---------- Japan: MOF JGB yield CSV ----------
function Parse-JgbCsv($csvText) {
    $out = New-Object System.Collections.Generic.List[object]
    $lines = $csvText -split "`r?`n"
    foreach ($line in $lines) {
        if ($line -notmatch '^\d{4}/\d{1,2}/\d{1,2},') { continue }
        $cols = $line -split ","
        if ($cols.Count -lt 11) { continue }
        $d = $cols[0]
        $y10 = $cols[10]
        if ($y10 -eq "-" -or [string]::IsNullOrWhiteSpace($y10)) { continue }
        try {
            $parts = $d -split "/"
            $date = [DateTime]::new([int]$parts[0], [int]$parts[1], [int]$parts[2])
            $out.Add([PSCustomObject]@{ Date = $date.ToString("yyyy-MM-dd"); Value = [double]$y10 })
        } catch { continue }
    }
    return , $out
}
function Get-JapanSeries() {
    try {
        $hist = Invoke-RestMethod -Uri "https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/historical/jgbcme_all.csv" -Headers $UA -TimeoutSec 30
        $current = $null
        try { $current = Invoke-RestMethod -Uri "https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/jgbcme.csv" -Headers $UA -TimeoutSec 30 } catch {}
        $combined = (Parse-JgbCsv $hist) + $(if ($current) { Parse-JgbCsv $current } else { @() })
        $byDate = [ordered]@{}
        foreach ($p in $combined) { $byDate[$p.Date] = $p.Value }
        $out = foreach ($k in ($byDate.Keys | Sort-Object)) { [PSCustomObject]@{ Date = $k; Value = $byDate[$k] } }
        return , $out
    } catch {
        Write-Host ("::error::Japan (MOF JGB) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

# ---------- Germany: Bundesbank SDMX ----------
function Get-GermanySeries() {
    try {
        $uri = "https://api.statistiken.bundesbank.de/rest/data/BBSIS/D.I.ZST.ZI.EUR.S1311.B.A604.R10XX.R.A.A._Z._Z.A?format=json&startPeriod=2000-01-01"
        $resp = Invoke-RestMethod -Uri $uri -Headers $UA -UseBasicParsing -TimeoutSec 30
        $series = $resp.data.dataSets[0].series
        $seriesKey = ($series.PSObject.Properties | Select-Object -First 1).Name
        $obsDim = $resp.data.structure.dimensions.observation | Where-Object { $_.id -eq "TIME_PERIOD" }
        $dates = $obsDim.values | ForEach-Object { $_.id }
        $obs = $series.$seriesKey.observations
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($idx in $obs.PSObject.Properties.Name) {
            $v = $obs.$idx[0]
            if ($null -eq $v -or $v -eq "") { continue }
            $dateIdx = [int]$idx
            if ($dateIdx -ge $dates.Count) { continue }
            $out.Add([PSCustomObject]@{ Date = $dates[$dateIdx]; Value = [double]$v })
        }
        return , ($out | Sort-Object Date)
    } catch {
        Write-Host ("::error::Germany (Bundesbank) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

# ---------- UK: Bank of England GLC nominal spot curve (Excel) ----------
function Get-BoeSheet5Xml($url) {
    $tmpZip = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $url -Headers $UA -OutFile $tmpZip -TimeoutSec 60 -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $outerZip = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
        try {
            # The outer download is a zip of one or more .xlsx files (themselves zips).
            $xlsxEntries = $outerZip.Entries | Where-Object { $_.Name -like "*Nominal*current month*.xlsx" -or $_.Name -like "*2025 to present*.xlsx" -or $_.Name -like "*Nominal*.xlsx" }
            $results = New-Object System.Collections.Generic.List[string]
            foreach ($entry in $xlsxEntries) {
                $tmpXlsx = [System.IO.Path]::GetTempFileName()
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tmpXlsx, $true)
                try {
                    $innerZip = [System.IO.Compression.ZipFile]::OpenRead($tmpXlsx)
                    try {
                        $sheet = $innerZip.Entries | Where-Object { $_.FullName -eq "xl/worksheets/sheet5.xml" }
                        if ($sheet) {
                            $reader = New-Object System.IO.StreamReader($sheet.Open())
                            $results.Add($reader.ReadToEnd())
                            $reader.Close()
                        }
                    } finally { $innerZip.Dispose() }
                } finally { Remove-Item $tmpXlsx -ErrorAction SilentlyContinue }
            }
            return , $results
        } finally { $outerZip.Dispose() }
    } finally {
        Remove-Item $tmpZip -ErrorAction SilentlyContinue
    }
}
function Parse-BoeSpotCurve10Y($xml) {
    $out = New-Object System.Collections.Generic.List[object]
    $dateMatches = [regex]::Matches($xml, '<c r="A(\d+)"[^>]*><v>([\d.]+)</v></c>')
    $valMatches = [regex]::Matches($xml, '<c r="U(\d+)"[^>]*><v>(-?[\d.]+)</v></c>')
    $dates = @{}
    foreach ($m in $dateMatches) { $dates[$m.Groups[1].Value] = [double]$m.Groups[2].Value }
    foreach ($m in $valMatches) {
        $row = $m.Groups[1].Value
        if ([int]$row -lt 6) { continue } # rows 1-5 are titles/headers/an error cell, not data
        if ($dates.ContainsKey($row)) {
            $date = [DateTime]::new(1899, 12, 30).AddDays($dates[$row])
            $out.Add([PSCustomObject]@{ Date = $date.ToString("yyyy-MM-dd"); Value = [double]$m.Groups[2].Value })
        }
    }
    return , $out
}
function Get-UkSeries() {
    try {
        $sheets = @()
        $sheets += Get-BoeSheet5Xml "https://www.bankofengland.co.uk/-/media/boe/files/statistics/yield-curves/latest-yield-curve-data.zip"
        $sheets += Get-BoeSheet5Xml "https://www.bankofengland.co.uk/-/media/boe/files/statistics/yield-curves/glcnominalddata.zip"
        $byDate = [ordered]@{}
        foreach ($xml in $sheets) {
            foreach ($p in (Parse-BoeSpotCurve10Y $xml)) { $byDate[$p.Date] = $p.Value }
        }
        $out = foreach ($k in ($byDate.Keys | Sort-Object)) { [PSCustomObject]@{ Date = $k; Value = $byDate[$k] } }
        return , $out
    } catch {
        Write-Host ("::error::UK (Bank of England) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

# ---------- Canada: Bank of Canada Valet API ----------
function Get-CanadaSeries() {
    try {
        $uri = "https://www.bankofcanada.ca/valet/observations/BD.CDN.10YR.DQ.YLD/json?start_date=2000-01-01"
        $resp = Invoke-RestMethod -Uri $uri -Headers $UA -UseBasicParsing -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($o in $resp.observations) {
            $v = $o.'BD.CDN.10YR.DQ.YLD'.v
            if ($null -ne $v -and $v -ne "") { $out.Add([PSCustomObject]@{ Date = $o.d; Value = [double]$v }) }
        }
        return , ($out | Sort-Object Date)
    } catch {
        Write-Host ("::error::Canada (Bank of Canada Valet) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

# ---------- Australia: RBA F2 CSV ----------
function Get-AustraliaSeries() {
    try {
        $csv = Invoke-RestMethod -Uri "https://www.rba.gov.au/statistics/tables/csv/f2-data.csv" -Headers $UA -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        $lines = $csv -split "`r?`n"
        foreach ($line in $lines) {
            if ($line -notmatch '^\d{1,2}-[A-Za-z]{3}-\d{4},') { continue }
            $cols = $line -split ","
            if ($cols.Count -lt 5) { continue }
            $y10 = $cols[4]
            if ([string]::IsNullOrWhiteSpace($y10)) { continue }
            try {
                $date = [DateTime]::ParseExact($cols[0], "d-MMM-yyyy", [System.Globalization.CultureInfo]::InvariantCulture)
                $out.Add([PSCustomObject]@{ Date = $date.ToString("yyyy-MM-dd"); Value = [double]$y10 })
            } catch { continue }
        }
        return , ($out | Sort-Object Date)
    } catch {
        Write-Host ("::error::Australia (RBA) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

# ---------- Fetch + validate + merge, one country at a time (source isolation) ----------
$COUNTRIES = [ordered]@{
    US = @{ Name = "United States"; Flag = "us"; MinCount = 1000; Fetch = { Get-UsSeries } }
    JP = @{ Name = "Japan";         Flag = "jp"; MinCount = 500;  Fetch = { Get-JapanSeries } }
    DE = @{ Name = "Germany";       Flag = "de"; MinCount = 500;  Fetch = { Get-GermanySeries } }
    GB = @{ Name = "United Kingdom"; Flag = "gb"; MinCount = 30;  Fetch = { Get-UkSeries } }
    CA = @{ Name = "Canada";        Flag = "ca"; MinCount = 500;  Fetch = { Get-CanadaSeries } }
    AU = @{ Name = "Australia";     Flag = "au"; MinCount = 500;  Fetch = { Get-AustraliaSeries } }
}

$raw = @{}
$sourceStatus = @{}
foreach ($cc in $COUNTRIES.Keys) {
    $meta = $COUNTRIES[$cc]
    Write-Output ("Fetching {0} ({1})..." -f $cc, $meta.Name)
    $fresh = & $meta.Fetch
    $result = Get-ValidatedMergedSeries -Fresh $fresh -Existing (Get-ExistingSeries $cc) -MinCount $meta.MinCount -Name $cc
    $raw[$cc] = $result.series
    $sourceStatus[$cc] = $result.status
    if ($raw[$cc].Count -gt 0) {
        Write-Output ("  {0}: {1} points, latest {2} = {3} [{4}]" -f $cc, $raw[$cc].Count, $raw[$cc][-1].Date, $raw[$cc][-1].Value, $result.status)
    } else {
        Write-Output ("  {0}: NO DATA available [{1}]" -f $cc, $result.status)
    }
}

$CRITICAL = @("US")
$missingCritical = $CRITICAL | Where-Object { $raw[$_].Count -eq 0 }
if ($missingCritical) {
    throw ("Critical series unusable (no fresh data and no cache): {0} - refusing to write data\global_rates_data.js." -f ($missingCritical -join ", "))
}

function Get-Changes($series) {
    $n = $series.Count
    if ($n -eq 0) { return @{ value = $null; asOfDate = $null; chg1d = $null; chg1w = $null; chg1m = $null } }
    $latest = $series[$n - 1]
    $latestDate = [DateTime]::Parse($latest.Date)
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
    return @{ value = [math]::Round($latest.Value, 3); asOfDate = $latest.Date; chg1d = $chg1d; chg1w = (Find-LookbackChange 7); chg1m = (Find-LookbackChange 30) }
}
function Round-Chg($stat) {
    $r = @{ value = $stat.value; asOfDate = $stat.asOfDate }
    foreach ($k in @("chg1d", "chg1w", "chg1m")) {
        $r[$k] = if ($null -ne $stat[$k]) { [math]::Round($stat[$k] * 100.0, 1) } else { $null } # yields in % -> bp
    }
    return $r
}
function To-SeriesJson($series) {
    return , $(foreach ($p in $series) { @{ d = $p.Date; v = [math]::Round($p.Value, 3) } })
}

$countriesOut = [ordered]@{}
$seriesOut = [ordered]@{}
foreach ($cc in $COUNTRIES.Keys) {
    $stat = Round-Chg (Get-Changes $raw[$cc])
    $countriesOut[$cc] = @{
        name = $COUNTRIES[$cc].Name
        flag = $COUNTRIES[$cc].Flag
        value = $stat.value
        asOfDate = $stat.asOfDate
        chg1d = $stat.chg1d
        chg1w = $stat.chg1w
        chg1m = $stat.chg1m
        freq = "daily"
    }
    $seriesOut[$cc] = To-SeriesJson $raw[$cc]
}

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$lastObservation = ($raw.Values | Where-Object { $_.Count -gt 0 } | ForEach-Object { $_[$_.Count - 1].Date } | Sort-Object -Descending | Select-Object -First 1)

$payload = @{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = $nowUtc
    lastObservation        = $lastObservation
    sourceStatus           = $sourceStatus
    countries               = $countriesOut
    series                  = $seriesOut
}

Write-DataFileAtomic -Path $outPath -VarName "GLOBAL_RATES_DATA" -Payload $payload -Depth 8
Write-Output "Global 10Y yields:"
foreach ($cc in $COUNTRIES.Keys) {
    Write-Output ("  {0}: {1}%  (as of {2})" -f $cc, $countriesOut[$cc].value, $countriesOut[$cc].asOfDate)
}

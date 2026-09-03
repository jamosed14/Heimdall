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
#   UK:        Bank of England "Government Liability Curve" spot curves - published as daily-
#              updated Excel workbooks (OOXML), not CSV. Sheet "4. spot curve" (internal file
#              worksheets/sheet5.xml, confirmed via workbook.xml/rels). Parsed by unzipping the
#              xlsx (it's a zip) and regexing the raw sheet XML directly - no Excel-parsing
#              module dependency. Nominal pulls the small "latest" (current-month) file every
#              run plus the bounded "2025 to present" archive (~1.5MB) for real history, NOT the
#              full 8-file/42MB 1979-present archive. Real and Inflation (breakeven) curves only
#              pull the current-month file (shallower history, but BoE publishes true matched-
#              tenor real and breakeven curves directly - not derived).
#   Canada:    Bank of Canada Valet API, series BD.CDN.10YR.DQ.YLD - clean documented REST API.
#   Australia: RBA statistical table F2 (capital market yields) - daily CSV, real history to 2013.
#              Also carries an "Indexed Bond" column at the same 10Y tenor, same file/date.
#
# Real yield / breakeven decomposition (DeltaNominal = DeltaReal + DeltaBreakeven), where a
# genuinely matched-tenor real yield exists: US (FRED DFII10 real + T10YIE breakeven, both
# official), UK (BoE's own matched-tenor Real/Inflation spot curves - a published breakeven, not
# derived - NOTE their column layout differs from the Nominal curve: Real/Inflation maturity
# headers start at 2.5Y not 0.5Y, so the 10Y column letter is NOT the same as Nominal's; the
# parser locates it dynamically per workbook, not by a hardcoded column), Australia (RBA's
# indexed-bond column - breakeven = nominal minus real, both from the same file/date/tenor, a
# clean subtraction). Canada's only free real yield is a long-term (not 10Y) Real Return Bond -
# kept as its own separate field, never combined into a breakeven, since that tenor mismatch
# would make a computed "Canada breakeven" actively misleading. Germany and Japan: no free
# matched-tenor real-yield source was found - not sourced, not guessed.

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

# ---------- US: FRED DGS10 (nominal), DFII10 (real/TIPS), T10YIE (breakeven) ----------
function Get-FredSimpleSeries($seriesId) {
    try {
        $uri = "https://api.stlouisfed.org/fred/series/observations?series_id=$seriesId&api_key=$FRED_API_KEY&file_type=json&observation_start=2000-01-01"
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($o in $resp.observations) {
            if ($o.value -ne ".") { $out.Add([PSCustomObject]@{ Date = $o.date; Value = [double]$o.value }) }
        }
        return , ($out | Sort-Object Date)
    } catch {
        Write-Host ("::error::FRED {0} fetch failed: {1}" -f $seriesId, $_.Exception.Message)
        return @()
    }
}
function Get-UsSeries() { return Get-FredSimpleSeries "DGS10" }
function Get-UsRealSeries() { return Get-FredSimpleSeries "DFII10" }
function Get-UsBreakevenSeries() { return Get-FredSimpleSeries "T10YIE" }

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

# ---------- UK: Bank of England GLC spot curves (nominal/real/inflation), Excel ----------
# IMPORTANT: the Real and Inflation (breakeven) curve workbooks do NOT share the Nominal
# workbook's column layout - Nominal's maturity header starts at 0.5Y (so 10Y lands on column
# U), but Real/Inflation start at 2.5Y (so their column U is 12Y, and 10Y is actually column Q).
# Confirmed by reading each workbook's own row-4 maturity header live before assuming anything -
# hardcoding one column letter for both would have silently mislabeled a 12Y point as 10Y.
# Because of that, the column is located dynamically per workbook rather than hardcoded.
function Get-BoeSheet5XmlList($url, $namePattern) {
    $tmpZip = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $url -Headers $UA -OutFile $tmpZip -TimeoutSec 60 -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $outerZip = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
        try {
            # The outer download is a zip of one or more .xlsx files (themselves zips).
            $xlsxEntries = $outerZip.Entries | Where-Object { $_.Name -like $namePattern }
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
# Finds which column letter holds the target maturity (e.g. 10.0) by reading row 4's own
# maturity header, then extracts that column's values for every data row (>=6).
function Parse-BoeSpotCurveAtMaturity($xml, [double]$targetMaturity) {
    $out = New-Object System.Collections.Generic.List[object]
    $headerMatch = [regex]::Match($xml, '<row r="4"[^>]*>(.*?)</row>')
    if (-not $headerMatch.Success) { return , $out }
    $headerCells = [regex]::Matches($headerMatch.Groups[1].Value, '<c r="([A-Z]+)4"[^>]*><v>([\d.]+)</v></c>')
    $targetCol = $null
    foreach ($hc in $headerCells) {
        if ([math]::Abs([double]$hc.Groups[2].Value - $targetMaturity) -lt 0.01) { $targetCol = $hc.Groups[1].Value; break }
    }
    if (-not $targetCol) { return , $out }

    $dateMatches = [regex]::Matches($xml, '<c r="A(\d+)"[^>]*><v>([\d.]+)</v></c>')
    $valMatches = [regex]::Matches($xml, '<c r="' + $targetCol + '(\d+)"[^>]*><v>(-?[\d.]+)</v></c>')
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
function Merge-ByDateLatestWins($lists) {
    $byDate = [ordered]@{}
    foreach ($list in $lists) { foreach ($p in $list) { $byDate[$p.Date] = $p.Value } }
    return , $(foreach ($k in ($byDate.Keys | Sort-Object)) { [PSCustomObject]@{ Date = $k; Value = $byDate[$k] } })
}
function Get-UkSeries() {
    try {
        $sheets = @()
        $sheets += Get-BoeSheet5XmlList "https://www.bankofengland.co.uk/-/media/boe/files/statistics/yield-curves/latest-yield-curve-data.zip" "*Nominal*.xlsx"
        $sheets += Get-BoeSheet5XmlList "https://www.bankofengland.co.uk/-/media/boe/files/statistics/yield-curves/glcnominalddata.zip" "*2025 to present*.xlsx"
        return Merge-ByDateLatestWins ($sheets | ForEach-Object { , (Parse-BoeSpotCurveAtMaturity $_ 10.0) })
    } catch {
        Write-Host ("::error::UK (Bank of England, nominal) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}
function Get-UkRealSeries() {
    try {
        $sheets = Get-BoeSheet5XmlList "https://www.bankofengland.co.uk/-/media/boe/files/statistics/yield-curves/latest-yield-curve-data.zip" "*Real*.xlsx"
        return Merge-ByDateLatestWins ($sheets | ForEach-Object { , (Parse-BoeSpotCurveAtMaturity $_ 10.0) })
    } catch {
        Write-Host ("::error::UK (Bank of England, real) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}
function Get-UkBreakevenSeries() {
    try {
        $sheets = Get-BoeSheet5XmlList "https://www.bankofengland.co.uk/-/media/boe/files/statistics/yield-curves/latest-yield-curve-data.zip" "*Inflation*.xlsx"
        return Merge-ByDateLatestWins ($sheets | ForEach-Object { , (Parse-BoeSpotCurveAtMaturity $_ 10.0) })
    } catch {
        Write-Host ("::error::UK (Bank of England, breakeven/inflation) fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

# ---------- Canada: Bank of Canada Valet API ----------
function Get-BocValetSeries($seriesName) {
    try {
        $uri = "https://www.bankofcanada.ca/valet/observations/$seriesName/json?start_date=2000-01-01"
        $resp = Invoke-RestMethod -Uri $uri -Headers $UA -UseBasicParsing -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($o in $resp.observations) {
            $v = $o.$seriesName.v
            if ($null -ne $v -and $v -ne "") { $out.Add([PSCustomObject]@{ Date = $o.d; Value = [double]$v }) }
        }
        return , ($out | Sort-Object Date)
    } catch {
        Write-Host ("::error::Canada ({0}) fetch failed: {1}" -f $seriesName, $_.Exception.Message)
        return @()
    }
}
function Get-CanadaSeries() { return Get-BocValetSeries "BD.CDN.10YR.DQ.YLD" }
# Real Return Bond yield is labeled "long-term" by the Bank of Canada, NOT a clean 10Y point -
# Canada's RRB program has historically only issued long-dated (~30Y) real bonds, so this is a
# genuine tenor mismatch against the 10Y nominal above. Surfaced as its own labeled figure, never
# combined into a computed "Canada breakeven" the way US/UK/Australia are - a mismatched-tenor
# breakeven would be actively misleading for exactly the real-vs-inflation question this exists
# to answer.
function Get-CanadaRrbSeries() { return Get-BocValetSeries "BD.CDN.RRB.DQ.YLD" }

# ---------- Australia: RBA F2 CSV (nominal 10Y + indexed-bond real 10Y, same file/date) ----------
function Get-AustraliaCsvColumn([int]$colIndex) {
    try {
        $csv = Invoke-RestMethod -Uri "https://www.rba.gov.au/statistics/tables/csv/f2-data.csv" -Headers $UA -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        $lines = $csv -split "`r?`n"
        foreach ($line in $lines) {
            if ($line -notmatch '^\d{1,2}-[A-Za-z]{3}-\d{4},') { continue }
            $cols = $line -split ","
            if ($cols.Count -le $colIndex) { continue }
            $v = $cols[$colIndex]
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            try {
                $date = [DateTime]::ParseExact($cols[0], "d-MMM-yyyy", [System.Globalization.CultureInfo]::InvariantCulture)
                $out.Add([PSCustomObject]@{ Date = $date.ToString("yyyy-MM-dd"); Value = [double]$v })
            } catch { continue }
        }
        return , ($out | Sort-Object Date)
    } catch {
        Write-Host ("::error::Australia (RBA F2, column {0}) fetch failed: {1}" -f $colIndex, $_.Exception.Message)
        return @()
    }
}
# F2's columns are Date,2Y,3Y,5Y,10Y,IndexedBond(10Y real) - confirmed via the file's own header
# row before writing this. Same file, same date, genuinely matched-tenor real/nominal pair.
function Get-AustraliaSeries() { return Get-AustraliaCsvColumn 4 }
function Get-AustraliaRealSeries() { return Get-AustraliaCsvColumn 5 }

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

# ---------- Real yield / breakeven decomposition, where sourceable ----------
# Delta10Y = DeltaRealYield + DeltaBreakevenInflation. Only wired up where a matched-tenor real
# yield is actually available: US (FRED DFII10 + published breakeven T10YIE), UK (BoE's own
# matched-tenor Real and Inflation spot curves - a true published breakeven, not derived), and
# Australia (RBA's indexed-bond column in the same file/date/10Y-tenor as the nominal column, so
# breakeven = nominal - real is a clean derivation here). Canada's only free real yield is a
# long-term (not 10Y) Real Return Bond, kept separate and never combined into a breakeven.
# Germany and Japan: no free matched-tenor real-yield source was found - not sourced, not guessed.
$SUPPLEMENTARY = [ordered]@{
    US_REAL = @{ MinCount = 500; Fetch = { Get-UsRealSeries } }
    US_BE   = @{ MinCount = 500; Fetch = { Get-UsBreakevenSeries } }
    # Keyed GB (not UK) to match $COUNTRIES' own country-code key for the United Kingdom -
    # Get-DecompStat below builds its lookup key as "<countryCode>_REAL"/"<countryCode>_BE", so
    # this has to agree with $COUNTRIES.GB or the UK's real/breakeven data silently never
    # attaches to its own country entry (caught by actually running this end to end - it did).
    GB_REAL = @{ MinCount = 1;   Fetch = { Get-UkRealSeries } }
    GB_BE   = @{ MinCount = 1;   Fetch = { Get-UkBreakevenSeries } }
    AU_REAL = @{ MinCount = 500; Fetch = { Get-AustraliaRealSeries } }
    CA_RRB  = @{ MinCount = 500; Fetch = { Get-CanadaRrbSeries } }
}
foreach ($k in $SUPPLEMENTARY.Keys) {
    $meta = $SUPPLEMENTARY[$k]
    Write-Output ("Fetching {0}..." -f $k)
    $fresh = & $meta.Fetch
    $result = Get-ValidatedMergedSeries -Fresh $fresh -Existing (Get-ExistingSeries $k) -MinCount $meta.MinCount -Name $k
    $raw[$k] = $result.series
    $sourceStatus[$k] = $result.status
    if ($raw[$k].Count -gt 0) {
        Write-Output ("  {0}: {1} points, latest {2} = {3} [{4}]" -f $k, $raw[$k].Count, $raw[$k][-1].Date, $raw[$k][-1].Value, $result.status)
    } else {
        Write-Output ("  {0}: NO DATA available [{1}]" -f $k, $result.status)
    }
}
# Australia publishes no direct breakeven - derive it, but only on dates where both the nominal
# and real columns actually have a value (same file, so this is a clean subtraction, not a
# cross-source date-matching guess).
$auNominalMap = @{}
foreach ($p in $raw["AU"]) { $auNominalMap[$p.Date] = $p.Value }
$auBreakeven = New-Object System.Collections.Generic.List[object]
foreach ($p in $raw["AU_REAL"]) {
    if ($auNominalMap.ContainsKey($p.Date)) { $auBreakeven.Add([PSCustomObject]@{ Date = $p.Date; Value = $auNominalMap[$p.Date] - $p.Value }) }
}
$raw["AU_BE"] = ($auBreakeven | Sort-Object Date)

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

function Get-DecompStat($key) {
    if (-not $raw.Contains($key) -or $raw[$key].Count -eq 0) { return $null }
    $s = Round-Chg (Get-Changes $raw[$key])
    return @{ value = $s.value; asOfDate = $s.asOfDate; chg1d = $s.chg1d; chg1w = $s.chg1w; chg1m = $s.chg1m }
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
        # Matched-tenor real yield / breakeven decomposition (DeltaNominal = DeltaReal +
        # DeltaBreakeven) - null where not sourced (Germany, Japan), never fabricated.
        real10y       = Get-DecompStat ($cc + "_REAL")
        breakeven10y  = Get-DecompStat ($cc + "_BE")
        # Canada only: a long-term (not 10Y) Real Return Bond yield, kept structurally distinct
        # from real10y so the front end can never accidentally present it as tenor-matched.
        realLongTerm  = if ($cc -eq "CA") { Get-DecompStat "CA_RRB" } else { $null }
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

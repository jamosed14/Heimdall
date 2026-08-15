# AI capital/industrial buildout tab. This is NOT an AI-stocks tracker - it monitors whether
# hyperscaler capital spending, semiconductor production, grid capacity, and infrastructure
# costs are keeping pace with the AI investment cycle. Sources: SEC EDGAR XBRL (company
# capex/revenue, no key required), FRED (semiconductor production, transformer/electrical
# equipment PPI, info-processing investment - reuses fred_config.ps1), EIA (electricity
# demand - reuses eia_config.ps1). Writes data\ai_data.js.
#
# SEC capex/revenue methodology (see also AI.html methodology notes):
#   Cash-flow-statement XBRL facts are often reported YTD-cumulative (e.g. a "Q3" fact
#   actually covers 9 months), not standalone-quarter. We detect this generically by fact
#   duration (~90 days = standalone quarter, reported directly; >100 days = cumulative,
#   and we derive standalone = this_cumulative - previous_cumulative_with_same_start_date).
#   This same rule naturally derives fiscal-Q4 too, since the 10-K full-year fact minus the
#   9-month fact falls out of the identical subtraction - no special-casing needed.
#   MSFT/ORCL have non-calendar fiscal years, so "aggregate hyperscaler" figures sum each
#   company's own latest/TTM quarter (own period-end dates, shown in the breakdown) rather
#   than pretending a synchronized calendar quarter exists across all five.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
# Local dev: dot-source the gitignored config files. CI (GitHub Actions): fall back to
# FRED_API_KEY/EIA_API_KEY env vars, populated from repo secrets - never written to disk there.
$fredConfigPath = Join-Path $root "fred_config.ps1"
if (Test-Path $fredConfigPath) {
    . $fredConfigPath
} elseif ($env:FRED_API_KEY) {
    $FRED_API_KEY = $env:FRED_API_KEY
} else {
    throw "FRED_API_KEY not found - create fred_config.ps1 locally or set the FRED_API_KEY env var/secret in CI."
}
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
$outPath = Join-Path $dataDir "ai_data.js"

$existingPayload = Get-ExistingPayload $outPath
if ($existingPayload) { Write-Output ("Existing cache found: generated {0}" -f $existingPayload.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }

$SEC_HEADERS = @{ "User-Agent" = "Heimdall Catallaxy (personal research dashboard) jamosed14@gmail.com" }

# ===================== SEC EDGAR: hyperscaler capex / revenue =====================

$COMPANIES = [ordered]@{
    MSFT  = @{ Cik = "0000789019"; Name = "Microsoft" }
    GOOGL = @{ Cik = "0001652044"; Name = "Alphabet" }
    AMZN  = @{ Cik = "0001018724"; Name = "Amazon" }
    META  = @{ Cik = "0001326801"; Name = "Meta Platforms" }
    ORCL  = @{ Cik = "0001341439"; Name = "Oracle" }
}

# Preference-ordered fallback chains - all five companies currently resolve on the first tag
# in each list (verified live), but the fallback exists so a future filing change degrades
# gracefully instead of silently breaking.
$REVENUE_TAGS = @("RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues")
$CAPEX_TAGS = @("PaymentsToAcquirePropertyPlantAndEquipment", "PaymentsForCapitalImprovements", "PaymentsToAcquireProductiveAssets")
$DA_TAGS = @("Depreciation")

function Get-SecConcept($cik, $tag) {
    $uri = "https://data.sec.gov/api/xbrl/companyconcept/CIK$cik/us-gaap/$tag.json"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $SEC_HEADERS -UseBasicParsing -TimeoutSec 30
    } catch {
        return $null
    }
    if (-not $resp.units.USD) { return $null }
    $facts = $resp.units.USD | Where-Object { $_.form -eq "10-Q" -or $_.form -eq "10-K" }
    if ($facts.Count -eq 0) { return $null }
    # Dedupe by (start,end); prefer the fact from the most recently-filed report (highest fy)
    # in case of restatement.
    $map = [ordered]@{}
    foreach ($f in $facts) {
        $key = "$($f.start)|$($f.end)"
        if (-not $map.Contains($key) -or $f.fy -gt $map[$key].fy) { $map[$key] = $f }
    }
    return , ($map.Values)
}

# Finds the tag in $tagList that is CURRENTLY ACTIVE for this company - i.e. has the most
# recent data - not just "first tag with any data." Companies sometimes stop using a tag
# mid-history (AMZN's PaymentsToAcquirePropertyPlantAndEquipment stops in 2017, superseded by
# PaymentsToAcquireProductiveAssets); picking "first with any data" would silently lock onto
# a stale, no-longer-updated tag. We never splice two tags together across a definition
# change (confirmed AMZN's two capex tags disagree on their one overlap year, so they are not
# interchangeable) - one tag, whichever is presently in use, for the company's full series.
function Get-FirstAvailableConcept($cik, $tagList) {
    $candidates = @()
    foreach ($tag in $tagList) {
        $facts = Get-SecConcept $cik $tag
        Start-Sleep -Milliseconds 150
        if ($facts -and $facts.Count -gt 0) {
            $maxEnd = ($facts | ForEach-Object { [DateTime]::Parse($_.end) } | Measure-Object -Maximum).Maximum
            $candidates += @{ tag = $tag; facts = $facts; maxEnd = $maxEnd }
        }
    }
    if ($candidates.Count -eq 0) { return $null }
    # Manual max-find, not Sort-Object -Property (observed to mis-sort hashtable arrays by a
    # [datetime] property on this PowerShell 5.1 install - -Descending silently came out
    # ascending, which picked a long-stale tag over the currently-active one).
    $best = $candidates[0]
    foreach ($c in $candidates) { if ($c.maxEnd -gt $best.maxEnd) { $best = $c } }
    return @{ tag = $best.tag; facts = $best.facts }
}

# Converts raw XBRL facts (possibly YTD-cumulative) into standalone-quarter values.
# Generic rule: group by start date; within a group, duration ~80-100 days is a standalone
# quarter used directly. Longer durations are only treated as fiscal-year-YTD cumulative (and
# chain-subtracted against the previous fact in the same group) when the group's start date is
# a CONFIRMED fiscal-year start - i.e. it also appears as the start of an actual 10-K
# (full-year, ~365-day) fact. Some filers (seen in AMZN's capex tag) also disclose rolling
# "trailing twelve months ended <mid-quarter date>" facts that happen to share a start date
# with a real quarter but are NOT fiscal-year-cumulative; without this guard those get
# chain-subtracted into garbage values that collide with (and can silently overwrite) a
# legitimate quarter ending on the same date. Longer-duration members of a non-fiscal-year-start
# group are discarded rather than guessed at.
function Get-StandaloneQuarters($facts) {
    # Confirmed fiscal-year starts come from actual 10-K (full-year) facts. Also derive the
    # recurring month/day pattern (e.g. every "01-01" for a calendar-FY filer) so the CURRENT,
    # still-in-progress fiscal year is recognized even before its own 10-K has been filed -
    # otherwise the most recent 1-2 quarters of cumulative data get conservatively (and
    # needlessly) dropped every year until the next 10-K posts.
    $fiscalYearStarts = @{}
    $fiscalYearMonthDays = @{}
    foreach ($f in $facts) {
        $dur = ([DateTime]::Parse($f.end) - [DateTime]::Parse($f.start)).Days
        if ($f.form -eq "10-K" -and $dur -ge 350 -and $dur -le 380) {
            $fiscalYearStarts[$f.start] = $true
            $fiscalYearMonthDays[([DateTime]::Parse($f.start)).ToString("MM-dd")] = $true
        }
    }

    $out = New-Object System.Collections.Generic.List[object]
    $byStart = $facts | Group-Object start
    foreach ($grp in $byStart) {
        $monthDay = ([DateTime]::Parse($grp.Name)).ToString("MM-dd")
        $isFyStart = $fiscalYearStarts.ContainsKey($grp.Name) -or $fiscalYearMonthDays.ContainsKey($monthDay)
        $sorted = $grp.Group | Sort-Object { [DateTime]::Parse($_.end) }
        $prevVal = $null
        $prevEnd = $null
        foreach ($f in $sorted) {
            $dur = ([DateTime]::Parse($f.end) - [DateTime]::Parse($f.start)).Days
            if ($dur -ge 80 -and $dur -le 100) {
                $out.Add([PSCustomObject]@{ Start = $f.start; End = $f.end; Value = [double]$f.val; Source = "reported" })
                $prevVal = [double]$f.val
                $prevEnd = $f.end
            } elseif ($dur -gt 100 -and $isFyStart) {
                if ($null -ne $prevVal) {
                    # This derived quarter's own start is the day after the previous cumulative
                    # fact's end - not $f.start, which is still the shared fiscal-year start.
                    $ownStart = ([DateTime]::Parse($prevEnd)).AddDays(1).ToString("yyyy-MM-dd")
                    $out.Add([PSCustomObject]@{ Start = $ownStart; End = $f.end; Value = ([double]$f.val - $prevVal); Source = "calc" })
                }
                $prevVal = [double]$f.val
                $prevEnd = $f.end
            }
            # durations under 80 days, or longer durations in a non-fiscal-year-start group
            # (e.g. rolling trailing-12-month disclosures), are skipped rather than guessed at.
        }
    }
    # Final dedupe by End date (a quarter should appear once). Prefer "reported" over "calc"
    # if both somehow land on the same end date, since a direct filing beats a derivation.
    $byEnd = [ordered]@{}
    foreach ($q in ($out | Sort-Object { [DateTime]::Parse($_.End) })) {
        if (-not $byEnd.Contains($q.End) -or ($q.Source -eq "reported" -and $byEnd[$q.End].Source -eq "calc")) {
            $byEnd[$q.End] = $q
        }
    }
    return , ($byEnd.Values | Sort-Object { [DateTime]::Parse($_.End) })
}

function Find-YoyQuarter($series, $currentEnd) {
    $target = ([DateTime]::Parse($currentEnd)).AddYears(-1)
    $best = $null
    $bestDiff = [double]::MaxValue
    foreach ($q in $series) {
        $diff = [math]::Abs(([DateTime]::Parse($q.End) - $target).TotalDays)
        if ($diff -le 20 -and $diff -lt $bestDiff) { $bestDiff = $diff; $best = $q }
    }
    return $best
}

function Get-Ttm($series, $endIndex) {
    if ($endIndex -lt 3) { return $null }
    $sum = 0.0
    for ($i = $endIndex - 3; $i -le $endIndex; $i++) { $sum += $series[$i].Value }
    return $sum
}

Write-Output "Fetching SEC EDGAR hyperscaler capex/revenue..."
$companyResults = [ordered]@{}
foreach ($ticker in $COMPANIES.Keys) {
    $cik = $COMPANIES[$ticker].Cik
    Write-Output "  $ticker (CIK $cik)..."

    $revConcept = Get-FirstAvailableConcept $cik $REVENUE_TAGS
    $capexConcept = Get-FirstAvailableConcept $cik $CAPEX_TAGS
    $daConcept = Get-FirstAvailableConcept $cik $DA_TAGS

    if (-not $revConcept -or -not $capexConcept) {
        Write-Output "    SKIPPED - missing revenue or capex tag"
        continue
    }

    $revQ = Get-StandaloneQuarters $revConcept.facts
    $capexQ = Get-StandaloneQuarters $capexConcept.facts
    $daQ = if ($daConcept) { Get-StandaloneQuarters $daConcept.facts } else { @() }

    if ($revQ.Count -eq 0 -or $capexQ.Count -eq 0) {
        Write-Output "    SKIPPED - no standalone quarters derivable"
        continue
    }

    $latestRevQ = $revQ[$revQ.Count - 1]
    $latestCapexQ = $capexQ[$capexQ.Count - 1]

    $revTtm = Get-Ttm $revQ ($revQ.Count - 1)
    $capexTtm = Get-Ttm $capexQ ($capexQ.Count - 1)

    $revYoyQ = Find-YoyQuarter $revQ $latestRevQ.End
    $capexYoyQ = Find-YoyQuarter $capexQ $latestCapexQ.End
    $revYoyPct = if ($revYoyQ -and $revYoyQ.Value -ne 0) { (($latestRevQ.Value / $revYoyQ.Value) - 1.0) * 100.0 } else { $null }
    $capexYoyPct = if ($capexYoyQ -and $capexYoyQ.Value -ne 0) { (($latestCapexQ.Value / $capexYoyQ.Value) - 1.0) * 100.0 } else { $null }

    # TTM YoY (sturdier than single-quarter YoY): TTM ending 4 quarters before the latest.
    $revTtmYoy = if ($revQ.Count -ge 8) { Get-Ttm $revQ ($revQ.Count - 5) } else { $null }
    $capexTtmYoy = if ($capexQ.Count -ge 8) { Get-Ttm $capexQ ($capexQ.Count - 5) } else { $null }
    $revTtmYoyPct = if ($revTtmYoy -and $revTtmYoy -ne 0) { (($revTtm / $revTtmYoy) - 1.0) * 100.0 } else { $null }
    $capexTtmYoyPct = if ($capexTtmYoy -and $capexTtmYoy -ne 0) { (($capexTtm / $capexTtmYoy) - 1.0) * 100.0 } else { $null }

    $capexOverRevTtmPct = if ($revTtm -and $revTtm -ne 0) { ($capexTtm / $revTtm) * 100.0 } else { $null }

    $latestDaQ = if ($daQ.Count -gt 0) { $daQ[$daQ.Count - 1] } else { $null }
    $daTagUsed = if ($daConcept) { $daConcept.tag } else { $null }

    $companyResults[$ticker] = @{
        name = $COMPANIES[$ticker].Name
        cik = $cik
        tags = @{ revenue = $revConcept.tag; capex = $capexConcept.tag; depreciation = $daTagUsed }
        latestQuarter = @{
            periodEnd = $latestCapexQ.End
            periodStart = $latestCapexQ.Start
            revenue = [math]::Round($latestRevQ.Value, 0)
            revenueSource = $latestRevQ.Source
            capex = [math]::Round($latestCapexQ.Value, 0)
            capexSource = $latestCapexQ.Source
            depreciation = if ($latestDaQ) { [math]::Round($latestDaQ.Value, 0) } else { $null }
        }
        ttm = @{
            periodEnd = $latestCapexQ.End
            revenue = [math]::Round($revTtm, 0)
            capex = [math]::Round($capexTtm, 0)
            capexOverRevenuePct = if ($null -ne $capexOverRevTtmPct) { [math]::Round($capexOverRevTtmPct, 2) } else { $null }
        }
        revenueYoYPct = if ($null -ne $revYoyPct) { [math]::Round($revYoyPct, 2) } else { $null }
        capexYoYPct = if ($null -ne $capexYoyPct) { [math]::Round($capexYoyPct, 2) } else { $null }
        ttmRevenueYoYPct = if ($null -ne $revTtmYoyPct) { [math]::Round($revTtmYoyPct, 2) } else { $null }
        ttmCapexYoYPct = if ($null -ne $capexTtmYoyPct) { [math]::Round($capexTtmYoyPct, 2) } else { $null }
        capexGrowthMinusRevenueGrowthPpt = if (($null -ne $capexTtmYoyPct) -and ($null -ne $revTtmYoyPct)) { [math]::Round($capexTtmYoyPct - $revTtmYoyPct, 2) } else { $null }
        series = @{
            revenue = ($revQ | ForEach-Object { @{ d = $_.End; v = [math]::Round($_.Value, 0); calc = ($_.Source -eq "calc") } })
            capex   = ($capexQ | ForEach-Object { @{ d = $_.End; v = [math]::Round($_.Value, 0); calc = ($_.Source -eq "calc") } })
        }
    }
    Write-Output ("    revenue thru {0}: {1:N0} (tag={2})  |  capex thru {3}: {4:N0} (tag={5})  |  {6} rev qtrs, {7} capex qtrs" -f `
        $latestRevQ.End, $latestRevQ.Value, $revConcept.tag, $latestCapexQ.End, $latestCapexQ.Value, $capexConcept.tag, $revQ.Count, $capexQ.Count)
}

# Source isolation: SEC being down must NOT block the FRED/EIA sections below (compute/power/
# infrastructure/capitalCycle have nothing to do with SEC's health). So this no longer throws
# and aborts the whole script - instead, on a SEC outage, the capital section specifically
# falls back to the existing cached capital section (marked stale), and the script continues.
# The only way capital ends up truly empty (not stale-but-present) is a first-ever run with SEC
# down and no prior cache to fall back to - "never coerce missing to zero" applies here too:
# that case gets nulls/empty structures, not a fabricated $0.
$secStatus = "ok"
if ($companyResults.Count -lt $COMPANIES.Count) {
    Write-Host ("::error::Only {0} of {1} companies resolved from SEC EDGAR (usually SEC rate-limiting/blocking this machine's IP - reliable from a residential/local IP, has failed from GitHub Actions runners before)." -f $companyResults.Count, $COMPANIES.Count)
    if ($existingPayload -and $existingPayload.capital -and $existingPayload.capital.companies -and ($existingPayload.capital.companies.PSObject.Properties | Measure-Object).Count -gt 0) {
        Write-Host "::warning::Falling back to existing cached capital section (stale)."
        $secStatus = "stale"
        $capitalSection = @{
            companies = $existingPayload.capital.companies
            aggregate = $existingPayload.capital.aggregate
            series    = $existingPayload.capital.series
        }
    } else {
        Write-Host "::error::No existing cached capital section either - capital will be unavailable, not zero-filled."
        $secStatus = "error"
        $capitalSection = @{
            companies = @{}
            aggregate = @{ companyCount = 0; latestQuarterCapex = $null; latestQuarterRevenue = $null; ttmCapex = $null; ttmRevenue = $null; ttmCapexYoYPct = $null; ttmRevenueYoYPct = $null; capexOverRevenuePct = $null; capexGrowthMinusRevenueGrowthPpt = $null }
            series    = @{ aggregateTtmCapex = @() }
        }
    }
} else {
    # ---- Aggregate across companies: each company's own latest quarter / own TTM, summed.
    # Not calendar-synchronized (MSFT/ORCL fiscal quarters don't align to calendar quarters) -
    # the per-company breakdown above preserves each company's actual period-end date so this
    # approximation is visible, not hidden.
    $aggLatestCapex = 0.0; $aggLatestRevenue = 0.0
    $aggTtmCapex = 0.0; $aggTtmRevenue = 0.0
    $aggTtmCapexYoyDen = 0.0; $aggTtmRevenueYoyDen = 0.0
    $companyCount = 0
    foreach ($ticker in $companyResults.Keys) {
        $c = $companyResults[$ticker]
        $aggLatestCapex += $c.latestQuarter.capex
        $aggLatestRevenue += $c.latestQuarter.revenue
        $aggTtmCapex += $c.ttm.capex
        $aggTtmRevenue += $c.ttm.revenue
        $companyCount++
    }
    # Aggregate TTM YoY needs each company's own prior-year TTM; recompute from series directly.
    foreach ($ticker in $companyResults.Keys) {
        $c = $companyResults[$ticker]
        $capexSeries = $c.series.capex
        $revSeries = $c.series.revenue
        if ($capexSeries.Count -ge 8) {
            $priorTtm = 0.0
            for ($i = $capexSeries.Count - 8; $i -le $capexSeries.Count - 5; $i++) { $priorTtm += $capexSeries[$i].v }
            $aggTtmCapexYoyDen += $priorTtm
        }
        if ($revSeries.Count -ge 8) {
            $priorTtm = 0.0
            for ($i = $revSeries.Count - 8; $i -le $revSeries.Count - 5; $i++) { $priorTtm += $revSeries[$i].v }
            $aggTtmRevenueYoyDen += $priorTtm
        }
    }
    $aggTtmCapexYoyPct = if ($aggTtmCapexYoyDen -ne 0) { (($aggTtmCapex / $aggTtmCapexYoyDen) - 1.0) * 100.0 } else { $null }
    $aggTtmRevenueYoyPct = if ($aggTtmRevenueYoyDen -ne 0) { (($aggTtmRevenue / $aggTtmRevenueYoyDen) - 1.0) * 100.0 } else { $null }

    $aggregate = @{
        companyCount = $companyCount
        latestQuarterCapex = [math]::Round($aggLatestCapex, 0)
        latestQuarterRevenue = [math]::Round($aggLatestRevenue, 0)
        ttmCapex = [math]::Round($aggTtmCapex, 0)
        ttmRevenue = [math]::Round($aggTtmRevenue, 0)
        ttmCapexYoYPct = if ($null -ne $aggTtmCapexYoyPct) { [math]::Round($aggTtmCapexYoyPct, 2) } else { $null }
        ttmRevenueYoYPct = if ($null -ne $aggTtmRevenueYoyPct) { [math]::Round($aggTtmRevenueYoyPct, 2) } else { $null }
        capexOverRevenuePct = if ($aggTtmRevenue -ne 0) { [math]::Round(($aggTtmCapex / $aggTtmRevenue) * 100.0, 2) } else { $null }
        capexGrowthMinusRevenueGrowthPpt = if (($null -ne $aggTtmCapexYoyPct) -and ($null -ne $aggTtmRevenueYoyPct)) { [math]::Round($aggTtmCapexYoyPct - $aggTtmRevenueYoyPct, 2) } else { $null }
    }

    # Aggregate TTM capex sampled at calendar quarter-ends (Mar/Jun/Sep/Dec 31): for each date,
    # sum each company's most-recently-known TTM as-of that date. An approximation (companies
    # report on different schedules/fiscal calendars) - not a synchronized true calendar sum.
    function Get-AggregateTtmSeries($companyResults) {
        $allDates = New-Object System.Collections.Generic.List[DateTime]
        $today = Get-Date
        $d = [DateTime]::new(2019, 3, 31)
        while ($d -le $today) {
            $allDates.Add($d)
            $d = $d.AddMonths(3)
            $lastDayOfQuarter = [DateTime]::new($d.Year, $d.Month, [DateTime]::DaysInMonth($d.Year, $d.Month))
            $d = $lastDayOfQuarter
        }
        $companyTtmPoints = @{}
        foreach ($ticker in $companyResults.Keys) {
            $s = $companyResults[$ticker].series.capex
            $pts = New-Object System.Collections.Generic.List[object]
            for ($i = 3; $i -lt $s.Count; $i++) {
                $sum = 0.0
                for ($j = $i - 3; $j -le $i; $j++) { $sum += $s[$j].v }
                $pts.Add(@{ d = [DateTime]::Parse($s[$i].d); v = $sum })
            }
            $companyTtmPoints[$ticker] = $pts
        }
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($qEnd in $allDates) {
            $sum = 0.0
            $anyData = $false
            foreach ($ticker in $companyTtmPoints.Keys) {
                $best = $null
                foreach ($p in $companyTtmPoints[$ticker]) {
                    if ($p.d -le $qEnd -and (($p.d - $qEnd).Days -ge -100)) {
                        if ($null -eq $best -or $p.d -gt $best.d) { $best = $p }
                    }
                }
                if ($best) { $sum += $best.v; $anyData = $true }
            }
            if ($anyData) { $out.Add(@{ d = $qEnd.ToString("yyyy-MM-dd"); v = [math]::Round($sum, 0) }) }
        }
        return , $out
    }
    $aggregateTtmCapexSeries = Get-AggregateTtmSeries $companyResults

    $capitalSection = @{
        companies = $companyResults
        aggregate = $aggregate
        series    = @{ aggregateTtmCapex = $aggregateTtmCapexSeries }
    }
}

# ===================== FRED: semiconductor / infrastructure / capital cycle =====================

# Never throws - a network/HTTP failure becomes an empty array, which Test-SeriesSane rejects
# and the per-series merge below then falls back to that series' cached history for.
function Get-FredSeries($seriesId) {
    try {
        $uri = "https://api.stlouisfed.org/fred/series/observations?series_id=$seriesId&api_key=$FRED_API_KEY&file_type=json&observation_start=2005-01-01"
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($o in $resp.observations) {
            if ($o.value -ne ".") { $out.Add([PSCustomObject]@{ Date = $o.date; Value = [double]$o.value }) }
        }
        return $out | Sort-Object Date
    } catch {
        Write-Host ("::error::FRED fetch failed for {0}: {1}" -f $seriesId, $_.Exception.Message)
        return @()
    }
}

function Get-ExistingAiSeries($key) {
    if ($existingPayload -and $existingPayload.series -and $existingPayload.series.$key) {
        return ConvertFrom-SeriesJson $existingPayload.series.$key
    }
    return @()
}

function To-SeriesJson($series, $digits) {
    return , $(foreach ($p in $series) { @{ d = $p.Date; v = [math]::Round($p.Value, $digits) } })
}

# % YoY for index/dollar-level series, matched on exact prior-period calendar date.
function Get-YoyPctSeries($series, $monthsBack) {
    $map = @{}
    foreach ($p in $series) { $map[$p.Date] = $p.Value }
    return , $(foreach ($p in $series) {
        $priorDate = ([DateTime]::Parse($p.Date)).AddMonths(-$monthsBack).ToString("yyyy-MM-dd")
        if ($map.ContainsKey($priorDate) -and $map[$priorDate] -ne 0) {
            [PSCustomObject]@{ Date = $p.Date; Value = (($p.Value / $map[$priorDate]) - 1.0) * 100.0 }
        }
    })
}

# Percentage-point change for series already expressed in percent (e.g. capacity utilization) -
# a subtraction, never a % change of a %.
function Get-PointChangeSeries($series, $monthsBack) {
    $map = @{}
    foreach ($p in $series) { $map[$p.Date] = $p.Value }
    return , $(foreach ($p in $series) {
        $priorDate = ([DateTime]::Parse($p.Date)).AddMonths(-$monthsBack).ToString("yyyy-MM-dd")
        if ($map.ContainsKey($priorDate)) {
            [PSCustomObject]@{ Date = $p.Date; Value = $p.Value - $map[$priorDate] }
        }
    })
}

function Get-LatestStat($series, $freq) {
    if ($series.Count -eq 0) { return @{ value = $null; asOfDate = $null; freq = $freq } }
    $latest = $series[$series.Count - 1]
    return @{ value = [math]::Round($latest.Value, 2); asOfDate = $latest.Date; freq = $freq }
}

Write-Output "Fetching FRED series..."
$fredSourceStatus = @{}
$FRED_SERIES_META = [ordered]@{
    semiIP = @{ id = "IPG3344S"; minCount = 100 }
    semiCapUtil = @{ id = "CAPUTLG3344S"; minCount = 100 }
    transformerPPI = @{ id = "WPU11740999"; minCount = 100 }
    elecEquipProd = @{ id = "IPG335S"; minCount = 100 }
    infoProcessingInvestment = @{ id = "A679RC1Q027SBEA"; minCount = 30 }
}
$fredRaw = @{}
foreach ($key in $FRED_SERIES_META.Keys) {
    $meta = $FRED_SERIES_META[$key]
    $fresh = Get-FredSeries $meta.id
    $result = Get-ValidatedMergedSeries -Fresh $fresh -Existing (Get-ExistingAiSeries $key) -MinCount $meta.minCount -Name $key
    $fredRaw[$key] = $result.series
    $fredSourceStatus[$key] = $result.status
    if ($fredRaw[$key].Count -gt 0) {
        Write-Output ("  {0} ({1}): {2} pts, latest {3}={4} [{5}]" -f $key, $meta.id, $fredRaw[$key].Count, $fredRaw[$key][-1].Date, $fredRaw[$key][-1].Value, $result.status)
    } else {
        Write-Output ("  {0} ({1}): NO DATA available [{2}]" -f $key, $meta.id, $result.status)
    }
}
$semiIP = $fredRaw["semiIP"]
$semiCapUtil = $fredRaw["semiCapUtil"]
$transformerPPI = $fredRaw["transformerPPI"]
$elecEquipProd = $fredRaw["elecEquipProd"]
$infoProcessingInvestment = $fredRaw["infoProcessingInvestment"]

$semiIPYoY = Get-YoyPctSeries $semiIP 12
$semiCapUtilChgPp = Get-PointChangeSeries $semiCapUtil 12
$transformerPPIYoY = Get-YoyPctSeries $transformerPPI 12
$elecEquipProdYoY = Get-YoyPctSeries $elecEquipProd 12
$infoProcessingInvestmentYoY = Get-YoyPctSeries $infoProcessingInvestment 3

$compute = @{
    semiIP = (Get-LatestStat $semiIP "monthly")
    semiIPYoYPct = (Get-LatestStat $semiIPYoY "monthly")
    semiCapUtil = (Get-LatestStat $semiCapUtil "monthly")
    semiCapUtilChgPp = (Get-LatestStat $semiCapUtilChgPp "monthly")
}
$infrastructure = @{
    transformerPPI = (Get-LatestStat $transformerPPI "monthly")
    transformerPPIYoYPct = (Get-LatestStat $transformerPPIYoY "monthly")
    elecEquipProd = (Get-LatestStat $elecEquipProd "monthly")
    elecEquipProdYoYPct = (Get-LatestStat $elecEquipProdYoY "monthly")
}
$capitalCycle = @{
    infoProcessingInvestment = (Get-LatestStat $infoProcessingInvestment "quarterly")
    infoProcessingInvestmentYoYPct = (Get-LatestStat $infoProcessingInvestmentYoY "quarterly")
}

# ===================== EIA: electricity demand (macro/grid proxy, NOT "AI electricity demand") =====================

Write-Output "Fetching EIA retail electricity sales (US total, all sectors)..."
function Get-EiaRetailSalesUS() {
    try {
        $uri = "https://api.eia.gov/v2/electricity/retail-sales/data/?api_key=$EIA_API_KEY&frequency=monthly&data%5B0%5D=sales&facets%5Bstateid%5D%5B%5D=US&facets%5Bsectorid%5D%5B%5D=ALL&sort%5B0%5D%5Bcolumn%5D=period&sort%5B0%5D%5Bdirection%5D=asc&length=5000&start=2010-01"
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($o in $resp.response.data) {
            if ($null -ne $o.sales -and $o.sales -ne "") { $out.Add([PSCustomObject]@{ Date = "$($o.period)-01"; Value = [double]$o.sales }) }
        }
        return $out | Sort-Object Date
    } catch {
        Write-Host ("::error::EIA retail-sales fetch failed: {0}" -f $_.Exception.Message)
        return @()
    }
}
$freshElecDemand = Get-EiaRetailSalesUS
$elecDemandResult = Get-ValidatedMergedSeries -Fresh $freshElecDemand -Existing (Get-ExistingAiSeries "elecDemand") -MinCount 100 -Name "elecDemand"
$elecDemand = $elecDemandResult.series
$fredSourceStatus["elecDemand"] = $elecDemandResult.status
if ($elecDemand.Count -gt 0) {
    Write-Output ("  retail-sales: {0} pts, latest {1}={2} [{3}]" -f $elecDemand.Count, $elecDemand[-1].Date, $elecDemand[-1].Value, $elecDemandResult.status)
} else {
    Write-Output ("  retail-sales: NO DATA available [{0}]" -f $elecDemandResult.status)
}

$elecDemandYoY = Get-YoyPctSeries $elecDemand 12
function Get-TtmSeries($series) {
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 11; $i -lt $series.Count; $i++) {
        $sum = 0.0
        for ($j = $i - 11; $j -le $i; $j++) { $sum += $series[$j].Value }
        $out.Add([PSCustomObject]@{ Date = $series[$i].Date; Value = $sum })
    }
    return , $out
}
$elecDemandTtm = Get-TtmSeries $elecDemand
$elecDemandTtmYoY = Get-YoyPctSeries $elecDemandTtm 12

$power = @{
    demand = (Get-LatestStat $elecDemand "monthly")
    demandYoYPct = (Get-LatestStat $elecDemandYoY "monthly")
    demandTtm = (Get-LatestStat $elecDemandTtm "monthly")
    demandTtmYoYPct = (Get-LatestStat $elecDemandTtmYoY "monthly")
}

# ===================== Write payload (atomic) =====================

$sourceStatus = @{ sec = $secStatus }
foreach ($k in $fredSourceStatus.Keys) { $sourceStatus[$k] = $fredSourceStatus[$k] }

# If BOTH the SEC-derived capital section AND every FRED/EIA series are unusable, there's
# nothing meaningful to publish (only possible on a first-ever run with every source down at
# once) - abort rather than write an all-empty shell.
function Get-KeyCount($obj) {
    if ($null -eq $obj) { return 0 }
    if ($obj -is [System.Collections.IDictionary]) { return $obj.Keys.Count }
    return ($obj.PSObject.Properties | Measure-Object).Count
}
$fredAnyUsable = ($fredRaw.Values | Where-Object { $_.Count -gt 0 } | Measure-Object).Count -gt 0
$capitalUsable = (Get-KeyCount $capitalSection.companies) -gt 0
if (-not $capitalUsable -and -not $fredAnyUsable -and $elecDemand.Count -eq 0) {
    throw "Every source (SEC, FRED, EIA) is unusable with no existing cache to fall back to - refusing to write data\ai_data.js."
}

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$fredDates = $fredRaw.Values | Where-Object { $_.Count -gt 0 } | ForEach-Object { $_[$_.Count - 1].Date }
$elecDate = if ($elecDemand.Count -gt 0) { $elecDemand[$elecDemand.Count - 1].Date } else { $null }
$lastObservation = (@($fredDates) + @($elecDate) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)

$payload = @{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh  = $nowUtc
    lastObservation        = $lastObservation
    sourceStatus           = $sourceStatus
    capital = $capitalSection
    compute = $compute
    power = $power
    infrastructure = $infrastructure
    capitalCycle = $capitalCycle
    series = @{
        semiIP = To-SeriesJson $semiIP 2
        semiCapUtil = To-SeriesJson $semiCapUtil 2
        transformerPPI = To-SeriesJson $transformerPPI 2
        elecEquipProd = To-SeriesJson $elecEquipProd 2
        infoProcessingInvestment = To-SeriesJson $infoProcessingInvestment 1
        elecDemand = To-SeriesJson $elecDemand 0
        elecDemandTtm = To-SeriesJson $elecDemandTtm 0
    }
}

Write-DataFileAtomic -Path $outPath -VarName "AI_DATA" -Payload $payload -Depth 10
Write-Output ("Aggregate TTM capex: {0:N0}  TTM revenue: {1:N0}  capex/rev: {2}%  capex YoY: {3}%  rev YoY: {4}%" -f `
    $aggregate.ttmCapex, $aggregate.ttmRevenue, $aggregate.capexOverRevenuePct, $aggregate.ttmCapexYoYPct, $aggregate.ttmRevenueYoYPct)

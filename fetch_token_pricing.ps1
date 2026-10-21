# Token / inference pricing tracker (AI tab). Writes data\token_pricing_data.js.
#
# Question it answers: what does a given level of model capability cost, and how fast is that
# falling? Frontier price vs the cheapest "near-frontier" and "mainstream" models is the
# commoditization signal; best open-weight vs frontier is the open/closed gap.
#
# Source: OpenRouter public models API (https://openrouter.ai/api/v1/models) - free, no key.
# A secondary aggregator, not a primary source: list prices are what OpenRouter charges, which
# for first-party closed models matches the lab's own list price, and for open-weight models is
# the price of OpenRouter's default routing. Capability scores are the Artificial Analysis
# Intelligence Index, carried by OpenRouter in each model's `benchmarks` field.
#   - AA periodically re-versions the index (new evals, rescaled), which can shift every
#     model's score at once. Floors are therefore defined RELATIVE to the current frontier
#     (>= 90% / >= 75% of the top score), not as fixed index levels, so a rescale doesn't
#     silently redefine a tier. A rescale can still step the index series themselves.
#   - "Open-weight" = OpenRouter lists a Hugging Face repo for the model (hugging_face_id).
#     Confirmed live: gpt-oss and Gemma are flagged; GPT/Claude/Gemini flagships aren't.
#
# Blended price = (3 x input + 1 x output) / 4, $ per 1M tokens - the standard 3:1 blend AA
# uses, so it's comparable with their published charts.
#
# Excluded from every calculation: OpenRouter's own routers ("openrouter/*", negative "price"),
# "~provider/..." latest-aliases (duplicates), ":free" (rate-limited promos, price 0) and
# ":batch" (async half-price variants - not comparable to interactive pricing, and confirmed
# live that some open-weight :batch listings are priced ABOVE their interactive endpoint),
# expired models, unscored models, and anything without a text output.
#
# History: OpenRouter only exposes current prices, so there's no backfill - the daily series
# starts the day this tracker was first run (2026-10-21) and accumulates one point per UTC day.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
$dataDir = Join-Path $root "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$outPath = Join-Path $dataDir "token_pricing_data.js"

$existing = Get-ExistingPayload $outPath
if ($existing) { Write-Output ("Existing cache found: generated {0}" -f $existing.generatedAtUtc) }
else { Write-Output "No existing cache found (first run, or previous file unreadable)." }

$SERIES_KEYS = @("frontierPrice", "floor90Price", "floor75Price", "bestOpenPrice", "frontierIndex", "bestOpenIndex", "openLagMonths")
$TOP_N = 12
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function To-Double($s) {
    $v = 0.0
    if ($null -eq $s) { return $null }
    if ([double]::TryParse([string]$s, [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)) { return $v }
    return $null
}

# ---------- Fetch + parse ----------
$models = $null
try {
    Write-Output "Fetching OpenRouter model list..."
    $resp = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/models" -Headers @{ "User-Agent" = "Heimdall Catallaxy (personal research dashboard; jamosed14@gmail.com)" } -TimeoutSec 60
            break
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Host ("::warning::OpenRouter request failed (attempt {0}/3), retrying: {1}" -f $attempt, $_.Exception.Message)
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    if (-not $resp.data -or $resp.data.Count -lt 200) { throw ("model list too short: {0} entries (expected 200+)" -f $resp.data.Count) }

    $today = (Get-Date).ToUniversalTime().Date
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($m in $resp.data) {
        $id = [string]$m.id
        if ($id -like "openrouter/*" -or $id.StartsWith("~") -or $id.Contains(":")) { continue }
        if (-not ($m.architecture.output_modalities -contains "text")) { continue }
        if ($m.expiration_date) {
            $exp = [DateTime]::MinValue
            if ([DateTime]::TryParse([string]$m.expiration_date, $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$exp) -and $exp.ToUniversalTime().Date -lt $today) { continue }
        }
        $idx = To-Double $m.benchmarks.artificial_analysis.intelligence_index
        $pin = To-Double $m.pricing.prompt
        $pout = To-Double $m.pricing.completion
        if ($null -eq $idx -or $null -eq $pin -or $null -eq $pout) { continue }
        if ($idx -le 0 -or $idx -gt 100 -or $pin -le 0 -or $pout -le 0) { continue }
        $inM = $pin * 1e6; $outM = $pout * 1e6
        $list.Add([PSCustomObject]@{
            id      = $id
            name    = [string]$m.name
            index   = $idx
            input   = $inM
            output  = $outM
            blended = (3.0 * $inM + $outM) / 4.0
            open    = [bool]$m.hugging_face_id
            created = [DateTimeOffset]::FromUnixTimeSeconds([int64]$m.created).UtcDateTime.ToString("yyyy-MM-dd")
        })
    }
    if ($list.Count -lt 100) { throw ("only {0} priced+scored models after filtering (expected 100+)" -f $list.Count) }
    $models = $list
    Write-Output ("  {0} models listed, {1} priced and scored after filtering" -f $resp.data.Count, $list.Count)
} catch {
    Write-Host ("::error::OpenRouter fetch failed: {0}" -f $_.Exception.Message)
}

# ---------- Derive snapshot ----------
function Get-Pick($m) {
    if ($null -eq $m) { return $null }
    return [ordered]@{
        id = $m.id; name = $m.name; index = [math]::Round($m.index, 1)
        blended = [math]::Round($m.blended, 4); input = [math]::Round($m.input, 4); output = [math]::Round($m.output, 4)
        open = $m.open; created = $m.created
    }
}
# Cheapest model at or above a share of the frontier score; ties broken toward the higher score.
function Get-Floor($pct, $frontierIndex) {
    $threshold = $pct * $frontierIndex
    $m = $models | Where-Object { $_.index -ge $threshold } | Sort-Object @{ Expression = "blended"; Ascending = $true }, @{ Expression = "index"; Descending = $true } | Select-Object -First 1
    $p = Get-Pick $m
    if ($p) { $p.threshold = [math]::Round($threshold, 1); $p.pctOfFrontier = [math]::Round($pct * 100) }
    return $p
}

$snapshot = $null
if ($models) {
    $ranked = $models | Sort-Object @{ Expression = "index"; Descending = $true }, @{ Expression = "blended"; Ascending = $true }
    $frontier = $ranked | Select-Object -First 1
    $bestOpen = $ranked | Where-Object { $_.open } | Select-Object -First 1
    $floor90 = Get-Floor 0.90 $frontier.index
    $floor75 = Get-Floor 0.75 $frontier.index
    $openPick = Get-Pick $bestOpen
    if ($openPick) {
        $openPick.gapPts = [math]::Round($frontier.index - $bestOpen.index, 1)
        # Open lag: how long after a closed model first reached the best open model's score did
        # that open model ship. Uses OpenRouter release dates of models still listed - old
        # closed models (GPT-4, 2023) are still listed, but a delisted closed model that got
        # there earlier would make this read short. Negative = open reached it first.
        $firstClosed = $models | Where-Object { -not $_.open -and $_.index -ge $bestOpen.index } | Sort-Object created | Select-Object -First 1
        if ($firstClosed) {
            $lagDays = ([DateTime]::Parse($bestOpen.created) - [DateTime]::Parse($firstClosed.created)).TotalDays
            $openPick.lagDays = [int]$lagDays
            $openPick.lagMonths = [math]::Round($lagDays / 30.44, 1)
            $openPick.lagRef = Get-Pick $firstClosed
        }
    }

    $snapshot = [ordered]@{
        date         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
        modelsScored = $models.Count
        frontier     = Get-Pick $frontier
        floor90      = $floor90
        floor75      = $floor75
        bestOpen     = $openPick
        premium90    = if ($floor90 -and $floor90.blended -gt 0) { [math]::Round($frontier.blended / $floor90.blended, 1) } else { $null }
        premium75    = if ($floor75 -and $floor75.blended -gt 0) { [math]::Round($frontier.blended / $floor75.blended, 1) } else { $null }
        topModels    = @($ranked | Select-Object -First $TOP_N | ForEach-Object { Get-Pick $_ })
    }
    Write-Output ("  frontier: {0} idx {1} @ `${2}/M | floor90: {3} @ `${4}/M | floor75: {5} @ `${6}/M | best open: {7} idx {8} @ `${9}/M" -f `
        $frontier.id, $frontier.index, [math]::Round($frontier.blended, 2), $floor90.id, $floor90.blended, $floor75.id, $floor75.blended, $bestOpen.id, $bestOpen.index, [math]::Round($bestOpen.blended, 2))
}

# ---------- Merge history / fail stale ----------
$status = "ok"
if (-not $snapshot) {
    if ($existing -and $existing.latest) {
        Write-Host "::warning::token pricing: keeping last known-good snapshot"
        $status = "stale"
    } else {
        throw "No usable OpenRouter data and no existing cache - refusing to write data\token_pricing_data.js."
    }
}

$todayPoints = @{}
if ($snapshot) {
    $todayPoints = @{
        frontierPrice = $snapshot.frontier.blended
        floor90Price  = if ($snapshot.floor90) { $snapshot.floor90.blended } else { $null }
        floor75Price  = if ($snapshot.floor75) { $snapshot.floor75.blended } else { $null }
        bestOpenPrice = if ($snapshot.bestOpen) { $snapshot.bestOpen.blended } else { $null }
        frontierIndex = $snapshot.frontier.index
        bestOpenIndex = if ($snapshot.bestOpen) { $snapshot.bestOpen.index } else { $null }
        openLagMonths = if ($snapshot.bestOpen -and $null -ne $snapshot.bestOpen.lagMonths) { $snapshot.bestOpen.lagMonths } else { $null }
    }
}
$seriesOut = [ordered]@{}
foreach ($k in $SERIES_KEYS) {
    $old = if ($existing -and $existing.series -and $existing.series.$k) { ConvertFrom-SeriesJson $existing.series.$k } else { @() }
    $fresh = @()
    if ($snapshot -and $null -ne $todayPoints[$k]) { $fresh = @([PSCustomObject]@{ Date = $snapshot.date; Value = [double]$todayPoints[$k] }) }
    $merged = if ($fresh.Count -gt 0) { Merge-SeriesByDate -Existing $old -Fresh $fresh } else { $old }
    $seriesOut[$k] = @($merged | ForEach-Object { @{ d = $_.Date; v = [math]::Round($_.Value, 4) } })
}

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$latest = if ($snapshot) { $snapshot } else { $existing.latest }
$payload = [ordered]@{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = if ($status -eq "ok") { $nowUtc } else { $existing.lastSuccessfulRefresh }
    lastObservation       = $latest.date
    historyStart          = if ($seriesOut.frontierPrice.Count -gt 0) { $seriesOut.frontierPrice[0].d } else { $null }
    sourceStatus          = @{ openrouter = $status }
    source                = "OpenRouter models API (list prices) + Artificial Analysis Intelligence Index (via OpenRouter)"
    latest                = $latest
    series                = $seriesOut
}

Write-DataFileAtomic -Path $outPath -VarName "TOKEN_PRICING_DATA" -Payload $payload -Depth 8
Write-Output ("Token pricing: status {0}, {1} days of history" -f $status, $seriesOut.frontierPrice.Count)

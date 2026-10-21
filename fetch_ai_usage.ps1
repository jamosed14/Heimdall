# OpenRouter usage trend (AI tab, "Who Uses What" cards). Writes data\ai_usage_data.js.
#
# Source: the "Top LLMs by weekly token usage" leaderboard embedded in https://openrouter.ai/rankings
# (server-rendered JSON in the page, not a documented API - so it's parsed defensively and fails
# stale if the page shape changes). Each of the top 20 rows carries weekly prompt/completion
# tokens and a week-over-week `change`, which lets us reconstruct LAST week's mix from a single
# fetch, so the trend is available from day one rather than after a week of history.
#
# Why a trend and not a level: OpenRouter's users skew heavily toward cheap/open models, and most
# closed-model traffic goes direct to the labs, so the open share here is biased high. The bias
# is roughly constant week to week, so the CHANGE in open share is the usable signal.
#
# Free (":free") variants are excluded - promo tiers would read as adoption. "Open-weight" = the
# OpenRouter models API lists a Hugging Face repo for the model. Rows that can't be matched to a
# model are excluded and counted in `unmatched`.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
$dataDir = Join-Path $root "data"
$outPath = Join-Path $dataDir "ai_usage_data.js"

$existing = Get-ExistingPayload $outPath
$UA = @{ "User-Agent" = "Mozilla/5.0 (Heimdall Catallaxy personal research dashboard; jamosed14@gmail.com)" }

$snapshot = $null
try {
    $html = (Invoke-WebRequest -Uri "https://openrouter.ai/rankings" -Headers $UA -UseBasicParsing -TimeoutSec 60).Content -replace '\\"', '"'
    $rx = '"date":"([^"]+)","model_permaslug":"([^"]+)","variant":"([^"]+)","total_completion_tokens":(\d+),"total_prompt_tokens":(\d+)[^{}]*?"change":(null|-?[\d.eE+-]+)'
    $rows = [regex]::Matches($html, $rx) | ForEach-Object {
        [PSCustomObject]@{
            week = $_.Groups[1].Value.Substring(0, 10); slug = $_.Groups[2].Value; variant = $_.Groups[3].Value
            tokens = [double]$_.Groups[4].Value + [double]$_.Groups[5].Value
            change = if ($_.Groups[6].Value -eq "null") { $null } else { [double]$_.Groups[6].Value }
        }
    }
    if ($rows.Count -lt 10) { throw ("only {0} leaderboard rows parsed (expected ~20) - page shape may have changed" -f $rows.Count) }

    $models = (Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/models" -Headers $UA -TimeoutSec 60).data
    $openBySlug = @{}
    foreach ($m in $models) { if ($m.canonical_slug -and -not $openBySlug.ContainsKey($m.canonical_slug)) { $openBySlug[$m.canonical_slug] = [bool]$m.hugging_face_id } }

    $now = @{ open = 0.0; closed = 0.0 }; $prev = @{ open = 0.0; closed = 0.0 }
    $unmatched = 0; $prevComplete = $true
    foreach ($r in $rows) {
        if ($r.variant -eq "free") { continue }
        if (-not $openBySlug.ContainsKey($r.slug)) { $unmatched++; continue }
        $k = if ($openBySlug[$r.slug]) { "open" } else { "closed" }
        $now[$k] += $r.tokens
        # Last week's tokens = this week / (1 + change). A null change means the model is new to
        # the leaderboard - it contributed ~nothing last week, which is the honest reading.
        if ($null -ne $r.change) {
            if ($r.change -le -1) { $prevComplete = $false } else { $prev[$k] += $r.tokens / (1.0 + $r.change) }
        }
    }
    $totNow = $now.open + $now.closed; $totPrev = $prev.open + $prev.closed
    if ($totNow -le 0) { throw "no paid, matched tokens in leaderboard" }
    $shareNow = 100.0 * $now.open / $totNow
    $sharePrev = if ($totPrev -gt 0 -and $prevComplete) { 100.0 * $prev.open / $totPrev } else { $null }
    $snapshot = [ordered]@{
        week           = ($rows | Select-Object -First 1).week
        openSharePct   = [math]::Round($shareNow, 1)
        openSharePrevPct = if ($null -ne $sharePrev) { [math]::Round($sharePrev, 1) } else { $null }
        wowChangePts   = if ($null -ne $sharePrev) { [math]::Round($shareNow - $sharePrev, 1) } else { $null }
        paidTokensT    = [math]::Round($totNow / 1e12, 1)
        rowsUsed       = $rows.Count
        unmatched      = $unmatched
    }
    Write-Output ("OpenRouter usage: week {0}, open share (paid) {1}% vs {2}% prior week ({3} pts), {4}T paid tokens, {5} unmatched" -f `
        $snapshot.week, $snapshot.openSharePct, $snapshot.openSharePrevPct, $snapshot.wowChangePts, $snapshot.paidTokensT, $unmatched)
} catch {
    Write-Host ("::error::OpenRouter usage fetch failed: {0}" -f $_.Exception.Message)
}

$status = "ok"
if (-not $snapshot) {
    if ($existing -and $existing.latest) { $status = "stale"; Write-Host "::warning::OpenRouter usage: keeping last known-good snapshot" }
    else { throw "No usable OpenRouter usage data and no cache - refusing to write data\ai_usage_data.js." }
}

# Weekly history of open share, keyed by the leaderboard's week date (re-runs within a week
# overwrite that week's point).
$old = if ($existing -and $existing.series -and $existing.series.openSharePct) { ConvertFrom-SeriesJson $existing.series.openSharePct } else { @() }
$hist = if ($snapshot) { Merge-SeriesByDate -Existing $old -Fresh @([PSCustomObject]@{ Date = $snapshot.week; Value = $snapshot.openSharePct }) } else { $old }

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$payload = [ordered]@{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = if ($status -eq "ok") { $nowUtc } else { $existing.lastSuccessfulRefresh }
    sourceStatus          = @{ openrouterRankings = $status }
    latest                = if ($snapshot) { $snapshot } else { $existing.latest }
    series                = @{ openSharePct = @($hist | ForEach-Object { @{ d = $_.Date; v = $_.Value } }) }
}
Write-DataFileAtomic -Path $outPath -VarName "AI_USAGE_DATA" -Payload $payload -Depth 6

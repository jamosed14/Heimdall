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
# Free (":free") variants are excluded from every share - promo tiers would read as adoption -
# and reported on their own as freeTokenSharePct (share of ALL top-20 tokens). "Open-weight" = the
# OpenRouter models API lists a Hugging Face repo for the model. Rows that can't be matched to a
# model are excluded and counted in `unmatched`.
#
# Spend = tokens x OpenRouter list price (prompt and completion priced separately). This is an
# UPPER BOUND: most of this volume is agentic input that's largely cache-read at a steep
# discount, and the leaderboard publishes cached tokens as 0, so caching can't be netted out.
# Because the overstatement is biggest on input-heavy, expensive models, spend shares are
# directional - the token-vs-spend split is the point, not the dollar total.
#
# Lab origin (US / China / Other) is by the model's provider prefix, from the explicit map below;
# anything unmapped lands in "other" rather than being guessed.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root "fetch_common.ps1")
$dataDir = Join-Path $root "data"
$outPath = Join-Path $dataDir "ai_usage_data.js"

$existing = Get-ExistingPayload $outPath
$UA = @{ "User-Agent" = "Mozilla/5.0 (Heimdall Catallaxy personal research dashboard; jamosed14@gmail.com)" }

$LAB_ORIGIN = @{}
foreach ($p in @("openai", "anthropic", "google", "meta", "meta-llama", "x-ai", "nvidia", "amazon", "microsoft", "perplexity", "ibm-granite", "allenai", "nousresearch", "arcee-ai", "liquid", "inflection")) { $LAB_ORIGIN[$p] = "us" }
foreach ($p in @("deepseek", "qwen", "alibaba", "z-ai", "thudm", "zhipu", "moonshotai", "minimax", "xiaomi", "tencent", "bytedance", "bytedance-seed", "stepfun", "baidu", "01-ai", "inclusionai", "meituan", "kwaipilot", "baichuan", "internlm")) { $LAB_ORIGIN[$p] = "china" }
function Get-Origin($slug) {
    $prefix = ($slug -split "/")[0]
    if ($LAB_ORIGIN.ContainsKey($prefix)) { return $LAB_ORIGIN[$prefix] }
    return "other"
}
function Pct($a, $b) { if ($b -gt 0) { return [math]::Round(100.0 * $a / $b, 1) } return $null }

$snapshot = $null
try {
    $html = (Invoke-WebRequest -Uri "https://openrouter.ai/rankings" -Headers $UA -UseBasicParsing -TimeoutSec 60).Content -replace '\\"', '"'
    $rx = '"date":"([^"]+)","model_permaslug":"([^"]+)","variant":"([^"]+)","total_completion_tokens":(\d+),"total_prompt_tokens":(\d+)[^{}]*?"change":(null|-?[\d.eE+-]+)'
    $rows = [regex]::Matches($html, $rx) | ForEach-Object {
        [PSCustomObject]@{
            week = $_.Groups[1].Value.Substring(0, 10); slug = $_.Groups[2].Value; variant = $_.Groups[3].Value
            outTok = [double]$_.Groups[4].Value; inTok = [double]$_.Groups[5].Value
            tokens = [double]$_.Groups[4].Value + [double]$_.Groups[5].Value
            change = if ($_.Groups[6].Value -eq "null") { $null } else { [double]$_.Groups[6].Value }
        }
    }
    if ($rows.Count -lt 10) { throw ("only {0} leaderboard rows parsed (expected ~20) - page shape may have changed" -f $rows.Count) }
    if (($rows.week | Select-Object -Unique).Count -ne 1) { throw "leaderboard rows span more than one week - page shape may have changed" }

    $models = (Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/models" -Headers $UA -TimeoutSec 60).data
    # Keyed by canonical slug + variant suffix, so a :batch row is priced at the batch price.
    $bySlug = @{}
    foreach ($m in $models) {
        if (-not $m.canonical_slug) { continue }
        $suffix = if ($m.id -like "*:free") { ":free" } elseif ($m.id -like "*:batch") { ":batch" } else { "" }
        $k = $m.canonical_slug + $suffix
        if (-not $bySlug.ContainsKey($k)) { $bySlug[$k] = $m }
    }
    function Find-Model($r) {
        $suffix = if ($r.variant -eq "free") { ":free" } elseif ($r.variant -eq "batch") { ":batch" } else { "" }
        if ($bySlug.ContainsKey($r.slug + $suffix)) { return $bySlug[$r.slug + $suffix] }
        if ($bySlug.ContainsKey($r.slug)) { return $bySlug[$r.slug] }
        return $null
    }

    $now = @{ open = 0.0; closed = 0.0 }; $prev = @{ open = 0.0; closed = 0.0 }
    $spend = @{ open = 0.0; closed = 0.0 }
    $originTok = @{ us = 0.0; china = 0.0; other = 0.0 }; $originSpend = @{ us = 0.0; china = 0.0; other = 0.0 }
    $allTokens = 0.0; $freeTokens = 0.0; $unmatchedTokens = 0.0
    $unmatched = 0; $prevComplete = $true
    $table = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        $allTokens += $r.tokens
        $m = Find-Model $r
        $isOpen = if ($m) { [bool]$m.hugging_face_id } else { $null }
        $rowOrigin = Get-Origin $r.slug
        $rowSpend = $null
        if ($m -and $r.variant -ne "free") {
            $pin = [double]$m.pricing.prompt; $pout = [double]$m.pricing.completion
            if ($pin -ge 0 -and $pout -ge 0) { $rowSpend = $r.inTok * $pin + $r.outTok * $pout }
        }
        $table.Add([ordered]@{
            slug = $r.slug; name = if ($m) { [string]$m.name } else { $r.slug }; variant = $r.variant
            tokensT = [math]::Round($r.tokens / 1e12, 2); changePct = if ($null -ne $r.change) { [math]::Round($r.change * 100.0, 1) } else { $null }
            open = $isOpen; origin = $rowOrigin; listSpendM = if ($null -ne $rowSpend) { [math]::Round($rowSpend / 1e6, 2) } else { $null }
        })

        if ($r.variant -eq "free") { $freeTokens += $r.tokens; continue }
        if (-not $m) { $unmatched++; $unmatchedTokens += $r.tokens; continue }
        $k = if ($isOpen) { "open" } else { "closed" }
        $now[$k] += $r.tokens
        $originTok[$rowOrigin] += $r.tokens
        if ($null -ne $rowSpend) { $spend[$k] += $rowSpend; $originSpend[$rowOrigin] += $rowSpend }
        # Last week's tokens = this week / (1 + change). A null change means the model is new to
        # the leaderboard - it contributed ~nothing last week, which is the honest reading.
        if ($null -ne $r.change) {
            if ($r.change -le -1) { $prevComplete = $false } else { $prev[$k] += $r.tokens / (1.0 + $r.change) }
        }
    }
    $totNow = $now.open + $now.closed; $totPrev = $prev.open + $prev.closed
    if ($totNow -le 0) { throw "no paid, matched tokens in leaderboard" }
    $totSpend = $spend.open + $spend.closed
    $shareNow = 100.0 * $now.open / $totNow
    $sharePrev = if ($totPrev -gt 0 -and $prevComplete) { 100.0 * $prev.open / $totPrev } else { $null }
    $snapshot = [ordered]@{
        week             = ($rows | Select-Object -First 1).week
        openSharePct     = [math]::Round($shareNow, 1)
        openSharePrevPct = if ($null -ne $sharePrev) { [math]::Round($sharePrev, 1) } else { $null }
        wowChangePts     = if ($null -ne $sharePrev) { [math]::Round($shareNow - $sharePrev, 1) } else { $null }
        paidTokensT      = [math]::Round($totNow / 1e12, 1)
        rowsUsed         = $rows.Count
        unmatched        = $unmatched
        # --- token vs spend split (paid, matched rows only) ---
        openSpendSharePct  = Pct $spend.open $totSpend
        listSpendM         = [math]::Round($totSpend / 1e6, 1)
        avgListPricePerM   = if ($totNow -gt 0) { [math]::Round($totSpend / ($totNow / 1e6), 3) } else { $null }
        origin             = [ordered]@{
            us    = @{ tokenPct = (Pct $originTok.us $totNow);    spendPct = (Pct $originSpend.us $totSpend) }
            china = @{ tokenPct = (Pct $originTok.china $totNow); spendPct = (Pct $originSpend.china $totSpend) }
            other = @{ tokenPct = (Pct $originTok.other $totNow); spendPct = (Pct $originSpend.other $totSpend) }
        }
        # --- free tier and unmatched, as shares of ALL top-20 tokens ---
        allTokensT         = [math]::Round($allTokens / 1e12, 1)
        freeTokenSharePct  = Pct $freeTokens $allTokens
        unmatchedTokenSharePct = Pct $unmatchedTokens $allTokens
        models             = @($table | Sort-Object { $_.tokensT } -Descending)
    }
    Write-Output ("OpenRouter usage: week {0}, open share (paid) {1}% vs {2}% prior week ({3} pts), {4}T paid tokens, {5} unmatched" -f `
        $snapshot.week, $snapshot.openSharePct, $snapshot.openSharePrevPct, $snapshot.wowChangePts, $snapshot.paidTokensT, $unmatched)
    Write-Output ("  open: {0}% of tokens vs {1}% of list-price spend | China {2}% / {3}% | US {4}% / {5}% | free tier {6}% of all tokens" -f `
        $snapshot.openSharePct, $snapshot.openSpendSharePct, $snapshot.origin.china.tokenPct, $snapshot.origin.china.spendPct, $snapshot.origin.us.tokenPct, $snapshot.origin.us.spendPct, $snapshot.freeTokenSharePct)
} catch {
    Write-Host ("::error::OpenRouter usage fetch failed: {0}" -f $_.Exception.Message)
}

$status = "ok"
if (-not $snapshot) {
    if ($existing -and $existing.latest) { $status = "stale"; Write-Host "::warning::OpenRouter usage: keeping last known-good snapshot" }
    else { throw "No usable OpenRouter usage data and no cache - refusing to write data\ai_usage_data.js." }
}

# Weekly history keyed by the leaderboard's week date (re-runs within a week overwrite that
# week's point). Each series merges independently so a field added later starts cleanly.
$HIST_FIELDS = [ordered]@{
    openSharePct       = { param($s) $s.openSharePct }
    openSpendSharePct  = { param($s) $s.openSpendSharePct }
    chinaTokenSharePct = { param($s) $s.origin.china.tokenPct }
    chinaSpendSharePct = { param($s) $s.origin.china.spendPct }
    freeTokenSharePct  = { param($s) $s.freeTokenSharePct }
    paidTokensT        = { param($s) $s.paidTokensT }
}
$seriesOut = [ordered]@{}
foreach ($k in $HIST_FIELDS.Keys) {
    $old = if ($existing -and $existing.series -and $existing.series.$k) { ConvertFrom-SeriesJson $existing.series.$k } else { @() }
    $v = if ($snapshot) { & $HIST_FIELDS[$k] $snapshot } else { $null }
    $mergedHist = if ($null -ne $v) { Merge-SeriesByDate -Existing $old -Fresh @([PSCustomObject]@{ Date = $snapshot.week; Value = [double]$v }) } else { $old }
    $seriesOut[$k] = @($mergedHist | ForEach-Object { @{ d = $_.Date; v = $_.Value } })
}

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$payload = [ordered]@{
    generatedAtUtc        = $nowUtc
    lastSuccessfulRefresh = if ($status -eq "ok") { $nowUtc } else { $existing.lastSuccessfulRefresh }
    sourceStatus          = @{ openrouterRankings = $status }
    latest                = if ($snapshot) { $snapshot } else { $existing.latest }
    series                = $seriesOut
}
Write-DataFileAtomic -Path $outPath -VarName "AI_USAGE_DATA" -Payload $payload -Depth 6

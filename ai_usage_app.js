// AI tab - "Who Uses What" cards. Three sources that each see a different slice of AI usage,
// shown side by side with a note on what each one actually measures. No single public source
// gives true open-vs-closed market share; see fetch_ai_usage.ps1 for why the OpenRouter card is a
// trend, not a level.
(function () {
  var grid = document.getElementById("group-usage");
  if (!grid) return;
  var M = window.AI_MARKET_SHARE_MANUAL || {};
  var U = window.AI_USAGE_DATA;

  function fmtDate(iso) {
    if (!iso) return "—";
    var parts = iso.split("-");
    var d = new Date(Date.UTC(+parts[0], +parts[1] - 1, parts[2] ? +parts[2] : 1));
    var opts = parts[2] ? { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" } : { month: "short", year: "numeric", timeZone: "UTC" };
    return d.toLocaleDateString("en-US", opts);
  }
  function pts(v) { return (v > 0 ? "+" : "") + v.toFixed(1) + " pts"; }
  function cls(v) { return v > 0 ? " positive" : v < 0 ? " negative" : ""; }

  function card(label, value, sub, subVal, note) {
    var el = document.createElement("div");
    el.className = "stat-card";
    el.innerHTML = '<div class="stat-label">' + label + '</div><div class="stat-value">' + value + "</div>" +
      (sub ? '<div class="stat-sub' + (subVal !== undefined && subVal !== null ? cls(subVal) : "") + '">' + sub + "</div>" : "") +
      '<div class="stat-subline" style="margin-top:8px; font-size:11px; color:var(--text-faint); line-height:1.4; font-family:var(--font-body);">' + note + "</div>";
    grid.appendChild(el);
  }

  // 1. OpenRouter - fast, biased; the trend is the signal.
  if (U && U.latest) {
    var L = U.latest;
    card("Open-Weight Share · OpenRouter", L.wowChangePts !== null ? pts(L.wowChangePts) : "—",
      "week over week · now " + L.openSharePct.toFixed(1) + "% of paid tokens (week of " + fmtDate(L.week) + ")", null,
      "OpenRouter's top 20 models by weekly tokens, free tiers excluded. Its users lean toward cheap open models and most closed-model traffic goes direct to the labs, so the level runs high — watch the direction. Prior week rebuilt from this week's top 20." +
      (U.sourceStatus && U.sourceStatus.openrouterRankings !== "ok" ? " Showing last good data." : ""));
  } else {
    card("Open-Weight Share · OpenRouter", "—", "no cached data — run fetch_ai_usage.ps1", null, "Weekly OpenRouter token leaderboard.");
  }

  // 2. Menlo - slow, closest to real enterprise market share.
  if (M.menlo) {
    var mm = M.menlo;
    card("Open-Source Share · Enterprise", mm.openSourceSharePct + "%",
      "of enterprise LLM API spend · " + mm.priorYearPct + "% a year earlier", null,
      'Menlo Ventures survey (' + fmtDate(mm.asOf) + '): spend estimated from each company\'s share of production API usage, weighted by app scale. Closest public read on real market share, but about yearly. Menlo is an Anthropic investor. <a href="' + mm.sourceUrl + '" target="_blank" rel="noopener" style="color:var(--accent-gold);">Source</a>');
  }

  // 3. Ramp - monthly, closed labs only.
  if (M.ramp) {
    var r = M.ramp;
    card("Business Adoption · Ramp", "Anthropic " + r.anthropicPct + "%",
      "OpenAI " + r.openaiPct + "% · any AI " + r.anyAiPct + "% (" + fmtDate(r.dataMonth) + ")", undefined,
      'Ramp AI Index: share of US businesses on Ramp paying each vendor, from card and bill-pay data. Counts who pays, not how much they use. Open models run on own servers or cloud bills barely show up, so this tracks the closed-lab race, not open share. <a href="' + r.sourceUrl + '" target="_blank" rel="noopener" style="color:var(--accent-gold);">Source</a>');
  }
})();

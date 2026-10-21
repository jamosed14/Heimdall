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

  // 1b. Token share vs spend share - who gets the volume vs who gets the money.
  if (U && U.latest && U.latest.openSpendSharePct !== null && U.latest.openSpendSharePct !== undefined) {
    card("Open-Weight · Tokens vs Spend", U.latest.openSharePct.toFixed(0) + "% / " + U.latest.openSpendSharePct.toFixed(0) + "%",
      "of paid tokens vs list-price spend (week of " + fmtDate(U.latest.week) + ")", null,
      "Open models take most of the volume but much less of the money. Spend is tokens × OpenRouter list price — an upper bound, since cached input is billed at a steep discount and the leaderboard doesn't publish cache use. Read the split, not the dollars.");
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

  // ---------- Token vs spend split + top models (OpenRouter) ----------
  function pct(v) { return v === null || v === undefined ? "—" : v.toFixed(1) + "%"; }
  function esc(s) {
    return String(s === null || s === undefined ? "" : s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }
  var LAB = { us: "US", china: "China", other: "Other" };
  var splitBody = document.getElementById("usageSplitBody");
  var modelsBody = document.getElementById("usageModelsBody");
  var note = document.getElementById("usageCalcNote");
  var L2 = U && U.latest;
  if (!L2 || L2.openSpendSharePct === undefined) {
    if (splitBody) splitBody.innerHTML = '<tr><td colspan="3">no cached breakdown — run fetch_ai_usage.ps1</td></tr>';
    return;
  }
  if (splitBody) {
    var o = L2.origin || {};
    var rows = [
      ["Open-weight", L2.openSharePct, L2.openSpendSharePct],
      ["Closed", 100 - L2.openSharePct, L2.openSpendSharePct === null ? null : 100 - L2.openSpendSharePct],
      ["US labs", o.us && o.us.tokenPct, o.us && o.us.spendPct],
      ["China labs", o.china && o.china.tokenPct, o.china && o.china.spendPct],
      ["Other labs", o.other && o.other.tokenPct, o.other && o.other.spendPct]
    ];
    splitBody.innerHTML = rows.map(function (r) {
      return "<tr><td>" + r[0] + "</td><td>" + pct(r[1]) + "</td><td>" + pct(r[2]) + "</td></tr>";
    }).join("") +
      '<tr><td>Free tier <span class="tag-note">(excluded above)</span></td><td>' + pct(L2.freeTokenSharePct) +
      ' <span class="tag-note">of all top-20 tokens</span></td><td>—</td></tr>';
  }
  if (modelsBody && L2.models) {
    modelsBody.innerHTML = L2.models.slice(0, 10).map(function (m) {
      var name = m.name && m.name.indexOf(": ") >= 0 ? m.name.slice(m.name.indexOf(": ") + 2) : (m.name || m.slug);
      var wow = m.changePct === null || m.changePct === undefined ? "new" : (m.changePct > 0 ? "+" : "") + m.changePct.toFixed(0) + "%";
      return "<tr><td>" + esc(name) + (m.variant === "free" && !/free/i.test(name) ? ' <span class="tag-note">free</span>' : "") + "</td><td>" + m.tokensT.toFixed(1) + "T</td><td>" + wow +
        "</td><td>" + (m.open === null || m.open === undefined ? "?" : m.open ? "open" : "closed") + "</td><td>" + (LAB[m.origin] || "Other") +
        "</td><td>" + (m.listSpendM === null || m.listSpendM === undefined ? "—" : "$" + m.listSpendM.toFixed(1) + "M") + "</td></tr>";
    }).join("");
  }
  if (note) {
    note.textContent = "OpenRouter top 20 models, week of " + fmtDate(L2.week) + ": " + L2.allTokensT + "T tokens, " + L2.paidTokensT +
      "T paid and matched. Lab origin is by provider (an explicit map; anything unmapped counts as Other). Spend is tokens × list price, an upper bound that ignores cache discounts." +
      (L2.unmatchedTokenSharePct ? " " + L2.unmatchedTokenSharePct.toFixed(1) + "% of tokens couldn't be matched to a listed model and are left out." : "") +
      " OpenRouter skews toward cheap open models, so watch the trend more than the level.";
  }
})();

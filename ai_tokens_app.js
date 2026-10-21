// AI tab - Inference Pricing section. Kept separate from ai_app.js (and fed by its own
// data/token_pricing_data.js from fetch_token_pricing.ps1) so a missing or failed token-pricing
// fetch never affects the rest of the AI tab, and vice versa.
(function () {
  var T = window.TOKEN_PRICING_DATA;
  var grid = document.getElementById("group-tokens");
  if (!grid) return;

  var COLORS = { frontierPrice: "#f7931a", floor90Price: "#7f97ab", floor75Price: "#7fae55", bestOpenPrice: "#c0574a" };
  var LABELS = { frontierPrice: "Frontier", floor90Price: "≥90% floor", floor75Price: "≥75% floor", bestOpenPrice: "Best open-weight" };
  var ORDER = ["frontierPrice", "floor90Price", "floor75Price", "bestOpenPrice"];

  function esc(s) {
    return String(s === null || s === undefined ? "" : s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }
  function fmtPrice(v) {
    if (v === null || v === undefined || !isFinite(v)) return "—";
    if (v >= 0.1) return "$" + v.toFixed(2);
    return "$" + v.toFixed(3);
  }
  // "Anthropic: Claude Opus 5.5" -> "Claude Opus 5.5" (the provider is implied by the model name).
  function shortName(m) {
    if (!m || !m.name) return m && m.id ? m.id : "—";
    var i = m.name.indexOf(": ");
    return i >= 0 ? m.name.slice(i + 2) : m.name;
  }

  function card(label, value, sub, tip) {
    var el = document.createElement("div");
    el.className = "stat-card";
    var labelHtml = tip ? '<span class="info-tip" data-tip="' + esc(tip) + '">' + label + "</span>" : label;
    el.innerHTML = '<div class="stat-label">' + labelHtml + '</div><div class="stat-value">' + value + "</div>" +
      (sub ? '<div class="stat-sub">' + sub + "</div>" : "");
    if (window.HeimdallFormat && T && T.latest) {
      window.HeimdallFormat.applyTooltip(el.querySelector(".stat-label"), T.latest.date, "daily", T.generatedAtUtc);
    }
    grid.appendChild(el);
  }

  if (!T || !T.latest || !T.latest.frontier) {
    grid.innerHTML = '<div class="stat-card"><div class="stat-label">Inference Pricing</div><div class="stat-value">—</div><div class="stat-sub">no cached data — run fetch_token_pricing.ps1</div></div>';
    return;
  }

  var L = T.latest;
  var f = L.frontier;
  card("Frontier", fmtPrice(f.blended), esc(shortName(f)) + " · index " + f.index.toFixed(1),
    "Highest Artificial Analysis Intelligence Index score among priced models. $" + f.input + " in / $" + f.output + " out per 1M tokens.");
  if (L.floor90) {
    card("Cheapest ≥90% of Frontier", fmtPrice(L.floor90.blended),
      esc(shortName(L.floor90)) + " · " + L.floor90.index.toFixed(1) + (L.premium90 ? " · frontier costs " + L.premium90 + "×" : ""),
      "Cheapest model scoring at least " + L.floor90.threshold + " (90% of the frontier's " + f.index.toFixed(1) + ").");
  }
  if (L.floor75) {
    card("Cheapest ≥75% of Frontier", fmtPrice(L.floor75.blended),
      esc(shortName(L.floor75)) + " · " + L.floor75.index.toFixed(1) + (L.premium75 ? " · frontier costs " + L.premium75 + "×" : ""),
      "Cheapest model scoring at least " + L.floor75.threshold + " (75% of the frontier's " + f.index.toFixed(1) + "). The commoditization line: how cheap 'good enough' has become.");
  }
  if (L.bestOpen) {
    card("Best Open-Weight", fmtPrice(L.bestOpen.blended),
      esc(shortName(L.bestOpen)) + " · " + L.bestOpen.index.toFixed(1) + " · " + L.bestOpen.gapPts.toFixed(1) + " pts behind frontier",
      "Highest-scoring model with published weights (OpenRouter lists a Hugging Face repo). The gap is the open/closed capability spread in index points.");
  }
  if (L.bestOpen && L.bestOpen.lagMonths !== null && L.bestOpen.lagMonths !== undefined && L.bestOpen.lagRef) {
    var ref = L.bestOpen.lagRef;
    var refDate = new Date(ref.created + "T00:00:00Z").toLocaleDateString("en-US", { month: "short", year: "numeric", timeZone: "UTC" });
    var lagVal = L.bestOpen.lagMonths <= 0 ? "at parity" : L.bestOpen.lagMonths.toFixed(1) + " mo";
    card("Open-Weight Lag", lagVal,
      esc(shortName(L.bestOpen)) + " reached the level " + esc(shortName(ref)) + " hit in " + refDate,
      "Months between a closed model first scoring at least the best open model's index (" + L.bestOpen.index.toFixed(1) +
      ") and that open model's release. Uses OpenRouter release dates of models still listed (closed models back to 2023 are), so a delisted earlier closed model would make this read short.");
  }

  // ---------- Chart ----------
  var series = T.series || {};
  var days = (series.frontierPrice || []).length;
  var sub = document.getElementById("tokenPriceSub");
  if (sub) {
    sub.textContent = "$ per 1M tokens (3:1 blend), daily since " + (T.historyStart || L.date) +
      (days < 2 ? " — history is building; lines appear after the second daily snapshot" : "");
  }
  if (window.HeimdallCharts) {
    window.HeimdallCharts.create({
      canvasId: "tokenPriceChart", csvButtonId: "tokenPriceCsvBtn", csvFilename: "inference_price_of_capability",
      defaultRange: "MAX",
      // Log by default: the frontier and the 75% floor sit ~40x apart.
      logToggleId: "tokenLogToggle", defaultLog: true,
      series: ORDER.map(function (k) {
        return { key: k, label: LABELS[k], color: COLORS[k], width: k === "frontierPrice" ? 3 : 2, rows: series[k] || [] };
      }),
      yFormatter: function (v) { return fmtPrice(v); }
    });
  }
  var legend = document.getElementById("tokenLegend");
  if (legend) {
    legend.innerHTML = ORDER.map(function (k) {
      return '<span class="legend-item"><span class="legend-dot" style="background:' + COLORS[k] + '"></span>' + LABELS[k] + "</span>";
    }).join("");
  }

  // ---------- Top models table ----------
  var body = document.getElementById("tokenTopBody");
  if (body && L.topModels) {
    body.innerHTML = L.topModels.map(function (m) {
      return "<tr><td>" + esc(m.name) + "</td><td>" + m.index.toFixed(1) + "</td><td>" + fmtPrice(m.blended) + "</td><td>" +
        fmtPrice(m.input) + "</td><td>" + fmtPrice(m.output) + "</td><td>" + (m.open ? "open" : "closed") + "</td></tr>";
    }).join("");
  }

  var note = document.getElementById("tokenCalcNote");
  if (note) {
    note.textContent = "Source: OpenRouter models API (list prices; open-weight models priced at OpenRouter's default routing) and the Artificial Analysis Intelligence Index as carried by OpenRouter. " +
      L.modelsScored + " models priced and scored today; free, batch, router and alias listings excluded. No price history exists upstream, so tracking began " +
      (T.historyStart || L.date) + ". A model sitting right at a floor threshold can flip the floor pick day to day, and Artificial Analysis occasionally re-versions its index, which can step the scores.";
  }
})();

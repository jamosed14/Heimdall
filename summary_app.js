(function () {
  var BTC = window.BTC_DATA;
  var MACRO = window.MACRO_DATA;
  var ENERGY = window.ENERGY_DATA;
  var EQUITIES = window.EQUITIES_DATA;

  function fmtPct(v, digits) {
    if (v === null || v === undefined) return "—";
    return v.toFixed(digits === undefined ? 2 : digits) + "%";
  }
  function fmtBps(delta) {
    if (delta === null || delta === undefined) return null;
    var bps = Math.round(delta * 100);
    return (bps > 0 ? "+" : "") + bps + "bp";
  }
  function fmtUsdScale(v) {
    if (v === null || v === undefined) return "—";
    var sign = v < 0 ? "-" : "";
    var abs = Math.abs(v);
    if (abs >= 1000) return sign + "$" + (abs / 1000).toFixed(2) + "T";
    if (abs >= 1) return sign + "$" + abs.toFixed(1) + "B";
    return sign + "$" + Math.round(abs * 1000) + "M";
  }
  function fmtUsdDelta(v) {
    if (v === null || v === undefined) return null;
    return (v > 0 ? "+" : "") + fmtUsdScale(v);
  }
  function fmtUsd(n) {
    if (n === null || n === undefined) return "—";
    return "$" + n.toLocaleString("en-US", { minimumFractionDigits: n >= 1000 ? 0 : 2, maximumFractionDigits: n >= 1000 ? 0 : 2 });
  }
  function monthLabel(dateStr) {
    if (!dateStr) return "";
    var d = new Date(dateStr + "T00:00:00Z");
    return d.toLocaleString("en-US", { month: "short", year: "numeric", timeZone: "UTC" });
  }

  // A row that isn't daily gets its date/frequency spelled out next to the value so a
  // once-a-week or once-a-month print never reads as "live."
  function freshTag(stat) {
    if (!stat || stat.freq === "daily" || !stat.asOfDate) return "";
    if (stat.freq === "monthly") return ' <span class="freq-badge">' + monthLabel(stat.asOfDate) + "</span>";
    return ' <span class="freq-badge">wk · ' + stat.asOfDate.slice(5) + "</span>";
  }

  // obsInfo: { obsDate, freq, generatedAtUtc, existingTip } - builds the standardized
  // Observation/Heimdall-checked tooltip on the row's label, appending after existingTip
  // (e.g. the Net Liquidity calc explanation) per the standing tooltip-ordering convention.
  function row(label, valueHtml, changeHtml, changeSign, obsInfo) {
    var cls = "sr-change";
    if (changeSign > 0) cls += " positive";
    else if (changeSign < 0) cls += " negative";
    var labelHtml = label;
    if (obsInfo && window.HeimdallFormat) {
      var tip = window.HeimdallFormat.obsTooltip(obsInfo.obsDate, obsInfo.freq, obsInfo.generatedAtUtc, obsInfo.existingTip);
      labelHtml = '<span class="info-tip" data-tip="' + tip.replace(/"/g, "&quot;") + '">' + label + "</span>";
    }
    return (
      '<div class="summary-row"><span class="sr-label">' + labelHtml + '</span>' +
      '<span class="sr-right"><span class="sr-value">' + valueHtml + "</span>" +
      (changeHtml ? '<span class="' + cls + '">' + changeHtml + "</span>" : "") +
      "</span></div>"
    );
  }

  function pctRow(label, stat, changeKey) {
    if (!stat || stat.value === null) return row(label, "—", null, 0);
    var chg = stat[changeKey];
    var obsInfo = { obsDate: stat.asOfDate, freq: stat.freq, generatedAtUtc: MACRO.generatedAtUtc };
    return row(label, fmtPct(stat.value) + freshTag(stat), fmtBps(chg), chg || 0, obsInfo);
  }

  function usdRow(label, stat, changeKey) {
    if (!stat || stat.value === null) return row(label, "—", null, 0);
    var chg = stat[changeKey];
    var obsInfo = { obsDate: stat.asOfDate, freq: stat.freq, generatedAtUtc: MACRO.generatedAtUtc };
    return row(label, fmtUsdScale(stat.value) + freshTag(stat), fmtUsdDelta(chg), chg || 0, obsInfo);
  }

  function monthlyRow(label, stat) {
    if (!stat || stat.value === null) return row(label, "—", null, 0);
    var delta = stat.priorValue !== null ? stat.value - stat.priorValue : null;
    var deltaText = delta === null ? null : (delta > 0 ? "+" : "") + delta.toFixed(2) + "pp vs prior";
    var obsInfo = { obsDate: stat.asOfDate, freq: "monthly", generatedAtUtc: MACRO.generatedAtUtc };
    return row(label, fmtPct(stat.value) + freshTag(stat), deltaText, delta || 0, obsInfo);
  }

  function fxRow(label, stat, digits) {
    if (!stat || stat.value === null) return row(label, "—", null, 0);
    var chg = stat.chg1d;
    var pctChg = chg !== null && stat.value !== chg ? (chg / (stat.value - chg)) * 100 : null;
    var obsInfo = { obsDate: stat.asOfDate, freq: stat.freq, generatedAtUtc: MACRO.generatedAtUtc };
    return row(label, stat.value.toFixed(digits), pctChg === null ? null : fmtPct(pctChg) + " 1D", chg || 0, obsInfo);
  }

  function blockHeader(title, href) {
    return '<div class="summary-block-header"><a href="' + href.replace(/&/g, "&amp;") + '">' + title + "</a><span class=\"arrow\">→</span></div>";
  }

  function buildBlocks() {
    var html = "";

    // ---- Bitcoin ----
    var btcStats = (BTC && BTC.stats) || {};
    html += '<div class="summary-block">' + blockHeader("Bitcoin", "BTC.html");
    var btcObsInfo = { obsDate: BTC ? BTC.asOfDate : null, freq: "daily", generatedAtUtc: BTC ? BTC.generatedAtUtc : null };
    html += row("BTC / USD", '<span id="sumBtcPrice" class="btc-live-mirror">' + fmtUsd(btcStats.price) + "</span>", null, 0, btcObsInfo);
    var premiumChg = btcStats.premiumPct;
    var premiumLabel = premiumChg === null || premiumChg === undefined ? "—" :
      fmtPct(premiumChg) + (premiumChg >= 0 ? " premium" : " discount");
    // id'd separately from the row() helper's usual output so updateLivePremium() below can
    // recompute this in place once the live ticker price is available - otherwise this row
    // would stay frozen at last night's cached close while the price right above it (via
    // .btc-live-mirror) keeps moving live, which is exactly the BTC-tab-vs-Summary mismatch
    // this was built to fix (BTC tab already recomputes its premium live in app.js).
    html += row("200W MA premium/discount", '<span id="sumBtcPremium">' + premiumLabel + "</span>", null, premiumChg || 0, btcObsInfo);
    html += row("30D realized vol", btcStats.vol30dPct === null || btcStats.vol30dPct === undefined ? "—" : btcStats.vol30dPct.toFixed(1) + "%", null, 0, btcObsInfo);
    html += '<div class="summary-block-foot">daily close ' + (BTC ? BTC.asOfDate : "—") + " · live ticker on BTC tab</div>";
    html += "</div>";

    // ---- Rates ----
    var rates = (MACRO && MACRO.rates) || {};
    html += '<div class="summary-block">' + blockHeader("Rates", "Rates.html");
    html += pctRow("2Y Treasury", rates.y2, "chg1d");
    html += pctRow("10Y Treasury", rates.y10, "chg1d");
    html += pctRow("30Y Treasury", rates.y30, "chg1d");
    html += pctRow("2s10s spread", rates.spread2s10, "chg1d");
    html += '<div class="summary-block-foot">Treasury daily par yields, as of ' + (rates.y10 ? rates.y10.asOfDate : "—") + " · changes in bps</div>";
    html += "</div>";

    // ---- Fed & Liquidity ----
    var fed = (MACRO && MACRO.fedLiquidity) || {};
    html += '<div class="summary-block">' + blockHeader("Fed & Liquidity", "Fed & Liquidity.html");
    html += pctRow("Effective Fed Funds", fed.fedFunds, "chg1d");
    html += usdRow("Fed total assets", fed.fedAssets, "chg1w");
    html += usdRow("Reserve balances", fed.reserves, "chg1w");
    html += usdRow("Treasury General Account", fed.tga, "chg1w");
    html += usdRow("ON RRP", fed.rrp, "chg1w");
    var netLiqTip = "Fed Total Assets − Treasury General Account − ON RRP. A commonly used shorthand for dollar system liquidity — our calculation, not an official Federal Reserve statistic.";
    html += row(
      "Net liquidity proxy" + '<span class="calc-badge">calc</span>',
      fmtUsdScale(fed.netLiquidity ? fed.netLiquidity.value : null) + freshTag(fed.netLiquidity),
      fed.netLiquidity ? fmtUsdDelta(fed.netLiquidity.chg1w) : null,
      fed.netLiquidity ? fed.netLiquidity.chg1w || 0 : 0,
      fed.netLiquidity ? { obsDate: fed.netLiquidity.asOfDate, freq: fed.netLiquidity.freq, generatedAtUtc: MACRO.generatedAtUtc, existingTip: netLiqTip } : null
    );
    html += '<div class="summary-block-foot">rates daily · balance-sheet weekly (Fed H.4.1) · net liquidity is our calculated proxy, not an official Fed figure</div>';
    html += "</div>";

    // ---- Inflation ----
    var infl = (MACRO && MACRO.inflation) || {};
    html += '<div class="summary-block">' + blockHeader("Inflation", "Inflation.html");
    html += monthlyRow("Headline CPI YoY", infl.cpiYoY);
    html += monthlyRow("Core CPI YoY", infl.coreCpiYoY);
    html += monthlyRow("Core PCE YoY", infl.corePceYoY);
    html += pctRow("10Y breakeven", infl.breakeven10y, "chg1d");
    html += '<div class="summary-block-foot">CPI/PCE are monthly releases, not live · breakeven is daily market pricing</div>';
    html += "</div>";

    // ---- Dollar / FX ----
    var fx = (MACRO && MACRO.fx) || {};
    html += '<div class="summary-block">' + blockHeader("Dollar & FX", "Dollar & FX.html");
    html += fxRow("DXY", fx.dxy, 2);
    html += fxRow("EUR/USD", fx.eurusd, 4);
    html += fxRow("USD/JPY", fx.usdjpy, 2);
    html += '<div class="summary-block-foot">DXY as of ' + (fx.dxy ? fx.dxy.asOfDate : "—") + " · FRED FX pairs as of " + (fx.eurusd ? fx.eurusd.asOfDate : "—") + "</div>";
    html += "</div>";

    // ---- Energy ----
    var prices = (ENERGY && ENERGY.prices) || {};
    var cracks = (ENERGY && ENERGY.cracks) || {};
    var inv = (ENERGY && ENERGY.inventories) || {};
    function usdRowEnergy(label, stat, digits) {
      if (!stat || stat.value === null) return row(label, "—", null, 0, null);
      var obsInfo = { obsDate: stat.asOfDate, freq: stat.freq, generatedAtUtc: ENERGY.generatedAtUtc };
      return row(label, "$" + stat.value.toFixed(digits), stat.chg1d === null ? null : (stat.chg1d > 0 ? "+$" : "-$") + Math.abs(stat.chg1d).toFixed(2) + " 1D", stat.chg1d || 0, obsInfo);
    }
    html += '<div class="summary-block">' + blockHeader("Energy", "Energy.html");
    html += usdRowEnergy("WTI", prices.wti, 2);
    html += usdRowEnergy("Brent", prices.brent, 2);
    html += usdRowEnergy("3:2:1 crack" + '<span class="calc-badge">calc</span>', cracks.crack321, 2);
    html += usdRowEnergy("Henry Hub", prices.henryHub, 3);
    if (inv.crudeStocks && inv.crudeStocks.value !== null) {
      var cs = inv.crudeStocks;
      var csObsInfo = { obsDate: cs.asOfDate, freq: cs.freq, generatedAtUtc: ENERGY.generatedAtUtc };
      var csChg = cs.chg1w;
      html += row("Crude stocks", cs.value.toLocaleString("en-US") + " kbbl", csChg === null ? null : (csChg > 0 ? "+" : "") + Math.round(csChg).toLocaleString("en-US") + " WoW", csChg || 0, csObsInfo);
    }
    html += '<div class="summary-block-foot">EIA daily spot prices · crack spread is our calculated proxy · stocks weekly</div>';
    html += "</div>";

    // ---- Equities ----
    var eqTickers = (EQUITIES && EQUITIES.tickers) || {};
    function equityRow(label, sym) {
      var t = eqTickers[sym];
      if (!t || t.price === null || t.price === undefined) return row(label, "—", null, 0);
      var obsInfo = { obsDate: t.asOfDate, freq: "daily", generatedAtUtc: EQUITIES.generatedAtUtc };
      var chg = t.chgPct;
      return row(label, fmtUsd(t.price), chg === null || chg === undefined ? null : fmtPct(chg) + " 1D", chg || 0, obsInfo);
    }
    html += '<div class="summary-block">' + blockHeader("Equities", "Equities.html");
    // MSTR (bitcoin balance-sheet proxy) ties back to the Bitcoin block above; NVDA and ORCL
    // are the two ends of the AI hyperscaler credit-stress story on the AI Buildout tab (ORCL
    // is the one under real CDS spread widening, NVDA the largest/most-watched name) - not an
    // arbitrary pick, meant to connect to what's already elsewhere on the dashboard rather than
    // duplicate the full 8-ticker watchlist here.
    html += equityRow("MSTR (Strategy)", "MSTR");
    html += equityRow("NVDA", "NVDA");
    html += equityRow("ORCL", "ORCL");
    html += '<div class="summary-block-foot">Yahoo Finance quotes, 15-min pre/regular/after-hours weekdays · informational only, not a licensed feed</div>';
    html += "</div>";

    document.getElementById("summaryGrid").innerHTML = html;
  }

  // ---------- Live-recomputed 200W MA premium/discount ----------
  // Mirrors BTC.html's app.js updateLiveDerivedStats: the BTC price row updates live via
  // ticker.js's .btc-live-mirror, but without this the premium/discount row sitting right next
  // to it would stay frozen at last night's cached close - the exact mismatch between this page
  // and the BTC tab that prompted this fix (BTC tab already recomputes its premium live).
  function parseLivePrice(text) {
    if (!text) return null;
    var n = parseFloat(text.replace(/[^0-9.\-]/g, ""));
    return (isFinite(n) && n > 0) ? n : null;
  }

  function updateLivePremium() {
    var premiumEl = document.getElementById("sumBtcPremium");
    if (!premiumEl) return; // grid not built yet, or this row absent (no BTC data)
    var ma200w = BTC && BTC.stats ? BTC.stats.ma200w : null;
    if (!ma200w) return;
    var livePrice = parseLivePrice(document.getElementById("liveBtcPrice") ? document.getElementById("liveBtcPrice").textContent : null);
    // No valid live price yet (still connecting, or ticker fetch failing) - fail stale: leave
    // whatever's already on screen (the cached-close value from buildBlocks) untouched.
    if (livePrice === null) return;
    var pct = ((livePrice - ma200w) / ma200w) * 100;
    premiumEl.textContent = fmtPct(pct) + (pct >= 0 ? " premium" : " discount");
  }

  var liveBtcMount = document.getElementById("liveBtcMount");
  if (liveBtcMount && window.MutationObserver) {
    new MutationObserver(updateLivePremium)
      .observe(liveBtcMount, { childList: true, subtree: true, characterData: true });
  }

  buildBlocks();
  updateLivePremium();
  document.getElementById("generatedNote").textContent =
    "BTC cache: " + (BTC ? BTC.generatedAtUtc : "—") + " · Macro cache: " + (MACRO ? MACRO.generatedAtUtc : "—");
  // Live ticker is handled by the shared ticker.js, included after this script.
})();

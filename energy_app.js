(function () {
  var DATA = window.ENERGY_DATA;

  function fmtUsd(v, digits) { return v === null || v === undefined ? "—" : "$" + v.toFixed(digits === undefined ? 2 : digits); }
  function fmtNum(v, digits) { return v === null || v === undefined ? "—" : v.toLocaleString("en-US", { minimumFractionDigits: digits || 0, maximumFractionDigits: digits || 0 }); }
  function buildChip(tag, text, val) {
    if (text === null) return "";
    var cls = "chg-chip" + (val > 0 ? " positive" : val < 0 ? " negative" : "");
    return '<span class="' + cls + '"><span class="chg-tag">' + tag + "</span>" + text + "</span>";
  }
  function usdChip(v) { return v === null || v === undefined ? null : (v > 0 ? "+$" : "-$") + Math.abs(v).toFixed(2); }
  function numChip(v, digits) { return v === null || v === undefined ? null : (v > 0 ? "+" : "") + fmtNum(v, digits); }

  // Energy's physical series (product stocks, refinery utilization, crack spreads) are
  // genuinely seasonal - a raw week-ago/month-ago delta can't distinguish a normal seasonal
  // draw/build from a real signal. This renders the "vs same calendar week, 5-year average"
  // comparison already computed server-side (fetch_energy_data.ps1's Get-SeasonalAvg) as a
  // distinct subscript line, separate from the chg-row's time-lookback chips since it's a
  // different kind of comparison (level vs seasonal norm, not a look-back-in-time).
  function seasonalSubline(vs5y, digits, showPct) {
    if (!vs5y || vs5y.diff === null || vs5y.diff === undefined) return "";
    var cls = vs5y.diff > 0 ? "positive" : vs5y.diff < 0 ? "negative" : "";
    var diffText = (vs5y.diff > 0 ? "+" : "") + fmtNum(vs5y.diff, digits) + (showPct ? "pp" : "");
    var pctText = (!showPct && vs5y.pct !== null && vs5y.pct !== undefined)
      ? " (" + (vs5y.pct > 0 ? "+" : "") + vs5y.pct.toFixed(1) + "%)" : "";
    return '<div class="stat-subline ' + cls + '">vs 5Y avg (same wk): ' + diffText + pctText + '</div>';
  }

  function card(label, valueHtml, chipsHtml, subHtml, stat, seasonalHtml) {
    var el = document.createElement("div");
    el.className = "stat-card";
    el.innerHTML =
      '<div class="stat-label">' + label + '</div>' +
      '<div class="stat-value">' + valueHtml + '</div>' +
      (seasonalHtml || "") +
      (chipsHtml ? '<div class="chg-row">' + chipsHtml + '</div>' : '') +
      (subHtml ? '<div class="stat-sub">' + subHtml + '</div>' : '');
    if (window.HeimdallFormat && stat) {
      window.HeimdallFormat.applyTooltip(el.querySelector(".stat-label"), stat.asOfDate, stat.freq, DATA.generatedAtUtc);
    }
    return el;
  }

  var PRICES = [
    { key: "wti", label: "WTI", digits: 2, unit: "$/bbl" },
    { key: "brent", label: "Brent", digits: 2, unit: "$/bbl" },
    { key: "henryHub", label: "Henry Hub", digits: 3, unit: "$/MMBtu" },
    { key: "rbob", label: "RBOB Gasoline (LA)", digits: 3, unit: "$/gal" },
    { key: "ulsd", label: "ULSD (NY Harbor)", digits: 3, unit: "$/gal" }
  ];
  var CRACKS = [
    { key: "crack321", label: "3:2:1 Crack" },
    { key: "crackGasoline", label: "Gasoline Crack" },
    { key: "crackDistillate", label: "Distillate Crack" }
  ];

  function renderPriceCards() {
    var el = document.getElementById("group-prices");
    PRICES.forEach(function (m) {
      var s = DATA.prices[m.key];
      if (!s || s.value === null) { el.appendChild(card(m.label, "—", null, "data unavailable")); return; }
      var chips = buildChip("1D", usdChip(s.chg1d), s.chg1d) + buildChip("1W", usdChip(s.chg1w), s.chg1w) +
        buildChip("1M", usdChip(s.chg1m), s.chg1m) + buildChip("YTD", usdChip(s.chgYtd), s.chgYtd);
      el.appendChild(card(m.label, fmtUsd(s.value, m.digits), chips, m.unit, s));
    });
  }

  function renderCrackCards() {
    var el = document.getElementById("group-cracks");
    CRACKS.forEach(function (m) {
      var s = DATA.cracks[m.key];
      if (!s || s.value === null) { el.appendChild(card(m.label, "—", null, "data unavailable")); return; }
      var chips = buildChip("1D", usdChip(s.chg1d), s.chg1d) + buildChip("1W", usdChip(s.chg1w), s.chg1w) + buildChip("1M", usdChip(s.chg1m), s.chg1m);
      var seasonal = seasonalSubline(DATA.cracks[m.key + "Vs5y"], 2, false);
      el.appendChild(card(m.label, fmtUsd(s.value, 2), chips, "$/bbl", s, seasonal));
    });
  }

  var INVENTORIES = [
    { key: "crudeStocks", label: "US Commercial Crude Stocks", unit: "thousand bbl" },
    { key: "cushingStocks", label: "Cushing Stocks", unit: "thousand bbl" },
    { key: "gasolineStocks", label: "Gasoline Stocks", unit: "thousand bbl" },
    { key: "distillateStocks", label: "Distillate Stocks", unit: "thousand bbl" },
    { key: "refineryUtilization", label: "Refinery Utilization", unit: "% of operable capacity", isPct: true },
    { key: "crudeProduction", label: "US Crude Production", unit: "thousand bbl/day" }
  ];

  function renderInventoryCards() {
    var el = document.getElementById("group-inventories");
    INVENTORIES.forEach(function (m) {
      var s = DATA.inventories[m.key];
      if (!s || s.value === null) { el.appendChild(card(m.label, "—", null, "data unavailable")); return; }
      var valueText = m.isPct ? s.value.toFixed(1) + "%" : fmtNum(s.value);
      var chipKey = m.key === "crudeProduction" ? "chg1m" : "chg1w";
      var chipTag = m.key === "crudeProduction" ? "m/m" : "WoW";
      var deltaFmt = m.isPct ? (s[chipKey] === null ? null : (s[chipKey] > 0 ? "+" : "") + s[chipKey].toFixed(1) + "pp") : numChip(s[chipKey]);
      var chips = buildChip(chipTag, deltaFmt, s[chipKey]);
      // Crude production deliberately has no seasonal comparison - it's driven by drilling/capex
      // cycles and well decline curves, not season (see fetch_energy_data.ps1).
      var seasonal = m.key === "crudeProduction" ? "" : seasonalSubline(DATA.inventories[m.key + "Vs5y"], m.isPct ? 1 : 0, !!m.isPct);
      el.appendChild(card(m.label, valueText, chips, m.unit, s, seasonal));
    });
  }

  function renderNatGasCards() {
    var el = document.getElementById("group-natgas");
    var hh = DATA.naturalGas.henryHub;
    if (hh && hh.value !== null) {
      var chips = buildChip("1D", usdChip(hh.chg1d), hh.chg1d) + buildChip("1W", usdChip(hh.chg1w), hh.chg1w);
      el.appendChild(card("Henry Hub", fmtUsd(hh.value, 3), chips, "$/MMBtu", hh));
    }
    var storage = DATA.naturalGas.workingGasStorage;
    if (storage && storage.value !== null) {
      var sChips = buildChip("WoW", numChip(storage.chg1w), storage.chg1w);
      el.appendChild(card("Working Gas in Storage", fmtNum(storage.value) + " Bcf", sChips, "Lower 48 states, weekly", storage));
    }
    var vs5y = DATA.naturalGas.storageVs5yAvg;
    if (vs5y && vs5y.diff !== null) {
      var vsCls = vs5y.diff > 0 ? "positive" : vs5y.diff < 0 ? "negative" : "";
      var vsChip = '<span class="chg-chip ' + vsCls + '">' + (vs5y.diff > 0 ? "+" : "") + fmtNum(vs5y.diff) + " Bcf (" + (vs5y.pct > 0 ? "+" : "") + vs5y.pct.toFixed(1) + "%)</span>";
      el.appendChild(card("Storage vs 5Y Avg", (vs5y.diff > 0 ? "+" : "") + fmtNum(vs5y.diff) + " Bcf", vsChip, "5Y avg = " + fmtNum(vs5y.avg) + " Bcf, same week of year", vs5y));
    }
  }

  function usdFmt(v) { return "$" + v.toFixed(0); }

  function renderCharts() {
    window.HeimdallCharts.create({
      canvasId: "chartCrude", rangeToggleId: "rangeToggle", csvButtonId: "chartCrudeCsvBtn", csvFilename: "wti_vs_brent",
      defaultRange: "3Y",
      series: [
        { key: "wti", label: "WTI", color: "#f7931a", rows: DATA.series.wti },
        { key: "brent", label: "Brent", color: "#7f97ab", dash: [3, 4], rows: DATA.series.brent }
      ],
      yFormatter: usdFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartCrack", rangeToggleId: "rangeToggle", csvButtonId: "chartCrackCsvBtn", csvFilename: "crack_321_spread",
      defaultRange: "3Y",
      series: [{ key: "crack321", label: "3:2:1 Crack", color: "#7fae55", fill: true, rows: DATA.series.crack321 }],
      yFormatter: usdFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartInv", rangeToggleId: "rangeToggle", csvButtonId: "chartInvCsvBtn", csvFilename: "crude_gasoline_distillate_stocks",
      defaultRange: "3Y",
      series: [
        { key: "crude", label: "Crude", color: "#f7931a", rows: DATA.series.crudeStocks },
        { key: "gasoline", label: "Gasoline", color: "#a89a7c", dash: [3, 4], rows: DATA.series.gasolineStocks },
        { key: "distillate", label: "Distillate", color: "#7f97ab", dash: [1, 3], rows: DATA.series.distillateStocks }
      ],
      yFormatter: function (v) { return fmtNum(v); }
    });
    window.HeimdallCharts.create({
      canvasId: "chartGasPrice", rangeToggleId: "rangeToggle", csvButtonId: "chartGasCsvBtn", csvFilename: "henry_hub_and_storage",
      defaultRange: "3Y",
      series: [{ key: "henryHub", label: "Henry Hub", color: "#f7931a", fill: true, rows: DATA.series.henryHub }],
      yFormatter: function (v) { return "$" + v.toFixed(1); }
    });
    window.HeimdallCharts.create({
      canvasId: "chartGasStorage", rangeToggleId: "rangeToggle",
      defaultRange: "3Y",
      series: [{ key: "storage", label: "Working Gas Storage", color: "#7f97ab", fill: true, rows: DATA.series.workingGasStorage }],
      yFormatter: function (v) { return fmtNum(v); }
    });
  }

  if (!DATA) {
    document.getElementById("asOfNote").textContent = "no cached data — run fetch_energy_data.ps1";
    return;
  }

  renderPriceCards();
  renderCrackCards();
  renderInventoryCards();
  renderNatGasCards();
  renderCharts();

  document.getElementById("asOfNote").textContent = "WTI as of " + DATA.prices.wti.asOfDate + " · stocks as of " + DATA.inventories.crudeStocks.asOfDate;
  document.getElementById("generatedNote").textContent = "Data cached " + DATA.generatedAtUtc + " · source: EIA (api.eia.gov), computed locally";
})();

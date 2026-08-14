(function () {
  var DATA = window.MACRO_DATA;

  function fmtPct(v, digits) {
    if (v === null || v === undefined) return "—";
    return v.toFixed(digits === undefined ? 2 : digits) + "%";
  }
  function fmtBpsChip(delta) {
    if (delta === null || delta === undefined) return null;
    var bps = Math.round(delta * 100);
    return (bps > 0 ? "+" : "") + bps + "bp";
  }
  function buildChip(tag, text, val) {
    if (text === null) return "";
    var cls = "chg-chip" + (val > 0 ? " positive" : val < 0 ? " negative" : "");
    return '<span class="' + cls + '"><span class="chg-tag">' + tag + "</span>" + text + "</span>";
  }
  function monthLabel(dateStr) {
    var d = new Date(dateStr + "T00:00:00Z");
    return d.toLocaleString("en-US", { month: "short", year: "numeric", timeZone: "UTC" });
  }

  var OBSERVED = [
    { key: "cpiYoY", label: "Headline CPI YoY" },
    { key: "coreCpiYoY", label: "Core CPI YoY" },
    { key: "pceYoY", label: "PCE YoY" },
    { key: "corePceYoY", label: "Core PCE YoY" }
  ];
  var EXPECTATIONS = [
    { key: "breakeven5y", label: "5Y Breakeven" },
    { key: "breakeven10y", label: "10Y Breakeven" }
  ];
  var ROBUST = [
    { key: "medianCpi", label: "Median CPI", unitNote: "m/m, ann. rate" },
    { key: "trimmedCpi", label: "16% Trimmed-Mean CPI", unitNote: "m/m, ann. rate" },
    { key: "stickyCpi", label: "Sticky-Price CPI", unitNote: "m/m" },
    { key: "coreStickyCpi", label: "Core Sticky-Price CPI", unitNote: "YoY" }
  ];

  function renderMonthlyCard(metric) {
    var stat = DATA.inflation[metric.key];
    var card = document.createElement("div");
    card.className = "stat-card";
    if (!stat || stat.value === null) {
      card.innerHTML = '<div class="stat-label">' + metric.label + '</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
      return card;
    }
    var delta = stat.priorValue !== null && stat.priorValue !== undefined ? stat.value - stat.priorValue : null;
    var deltaText = delta === null ? "" : (delta > 0 ? "+" : "") + delta.toFixed(2) + "pp vs prior month";
    var unitBadge = metric.unitNote ? ' <span class="freq-badge">' + metric.unitNote + '</span>' : ' <span class="freq-badge">monthly</span>';
    card.innerHTML =
      '<div class="stat-label">' + metric.label + unitBadge + '</div>' +
      '<div class="stat-value">' + fmtPct(stat.value) + '</div>' +
      '<div class="stat-sub">' + deltaText + (stat.priorValue !== null ? " (" + fmtPct(stat.priorValue) + ")" : "") + '</div>' +
      '<div class="stat-sub">' + monthLabel(stat.asOfDate) + ' release</div>';
    if (window.HeimdallFormat) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), stat.asOfDate, "monthly", DATA.generatedAtUtc);
    }
    return card;
  }

  function renderDailyCard(metric) {
    var stat = DATA.inflation[metric.key];
    var card = document.createElement("div");
    card.className = "stat-card";
    if (!stat || stat.value === null) {
      card.innerHTML = '<div class="stat-label">' + metric.label + '</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
      return card;
    }
    var chips = buildChip("1D", fmtBpsChip(stat.chg1d), stat.chg1d) +
      buildChip("1W", fmtBpsChip(stat.chg1w), stat.chg1w) +
      buildChip("1M", fmtBpsChip(stat.chg1m), stat.chg1m);
    card.innerHTML =
      '<div class="stat-label">' + metric.label + '</div>' +
      '<div class="stat-value">' + fmtPct(stat.value) + '</div>' +
      '<div class="chg-row">' + chips + '</div>';
    if (window.HeimdallFormat) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), stat.asOfDate, stat.freq, DATA.generatedAtUtc);
    }
    return card;
  }

  function fmtUsdB(v) {
    if (v === null || v === undefined) return "—";
    return "$" + (v / 1000).toFixed(2) + "T";
  }

  function renderMoneyCards() {
    var el = document.getElementById("group-money");

    var m2 = DATA.inflation.m2;
    var m2Card = document.createElement("div");
    m2Card.className = "stat-card";
    if (m2 && m2.value !== null) {
      var m2Chips = buildChip("1M", m2.chg1m === null ? null : (m2.chg1m > 0 ? "+" : "") + fmtUsdB(m2.chg1m), m2.chg1m);
      m2Card.innerHTML =
        '<div class="stat-label">M2 Money Stock</div>' +
        '<div class="stat-value">' + fmtUsdB(m2.value) + '</div>' +
        '<div class="chg-row">' + m2Chips + '</div>';
      if (window.HeimdallFormat) window.HeimdallFormat.applyTooltip(m2Card.querySelector(".stat-label"), m2.asOfDate, m2.freq, DATA.generatedAtUtc);
    }
    el.appendChild(m2Card);
    el.appendChild(renderMonthlyCard({ key: "m2YoY", label: "M2 YoY" }));

    var ratio = DATA.inflation.m2OverNominalGdp;
    var ratioCard = document.createElement("div");
    ratioCard.className = "stat-card";
    if (ratio && ratio.value !== null) {
      var ratioChips = buildChip("q/q", ratio.chg1w === null ? null : (ratio.chg1w > 0 ? "+" : "") + ratio.chg1w.toFixed(2) + "pp", ratio.chg1w);
      ratioCard.innerHTML =
        '<div class="stat-label">M2 / Nominal GDP <span class="freq-badge">quarterly</span></div>' +
        '<div class="stat-value">' + fmtPct(ratio.value, 1) + '</div>' +
        '<div class="chg-row">' + ratioChips + '</div>';
      if (window.HeimdallFormat) window.HeimdallFormat.applyTooltip(ratioCard.querySelector(".stat-label"), ratio.asOfDate, ratio.freq, DATA.generatedAtUtc);
    }
    el.appendChild(ratioCard);

    var vel = DATA.inflation.m2Velocity;
    var velCard = document.createElement("div");
    velCard.className = "stat-card";
    if (vel && vel.value !== null) {
      var velChips = buildChip("q/q", vel.chg1w === null ? null : (vel.chg1w > 0 ? "+" : "") + vel.chg1w.toFixed(3), vel.chg1w);
      var velTip = "FRED's own series (M2V) = Nominal GDP ÷ quarterly-average M2 — the inverse of M2/Nominal GDP above, published directly by the Fed rather than derived here.";
      velCard.innerHTML =
        '<div class="stat-label"><span class="info-tip" data-tip="' + velTip + '">M2 Velocity</span> <span class="freq-badge">quarterly</span></div>' +
        '<div class="stat-value">' + vel.value.toFixed(3) + '</div>' +
        '<div class="chg-row">' + velChips + '</div>';
      if (window.HeimdallFormat) window.HeimdallFormat.applyTooltip(velCard.querySelector(".stat-label"), vel.asOfDate, vel.freq, DATA.generatedAtUtc);
    }
    el.appendChild(velCard);
  }

  function renderHeimdallCards() {
    var el = document.getElementById("group-heimdall");
    var infl = DATA.inflation;
    document.getElementById("cpiBaseNote").textContent = monthLabel(infl.cpiBaseDate);

    function idxCard(label, stat, tip) {
      var card = document.createElement("div");
      card.className = "stat-card";
      if (!stat || stat.value === null) {
        card.innerHTML = '<div class="stat-label">' + label + '</div><div class="stat-value">—</div>';
        return card;
      }
      card.innerHTML =
        '<div class="stat-label">' + label + '</div>' +
        '<div class="stat-value">' + stat.value.toFixed(1) + '</div>' +
        '<div class="stat-sub">base = 100 at ' + monthLabel(infl.cpiBaseDate) + '</div>';
      if (window.HeimdallFormat) {
        window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), stat.asOfDate, stat.freq, DATA.generatedAtUtc, tip);
      }
      return card;
    }

    el.appendChild(idxCard("Purchasing Power Index", infl.purchasingPower));
    el.appendChild(idxCard("Price Level Index", infl.priceLevel));

    var lossCard = document.createElement("div");
    lossCard.className = "stat-card";
    if (infl.purchasingPower && infl.purchasingPower.value !== null) {
      var lossPct = 100 - infl.purchasingPower.value;
      lossCard.innerHTML =
        '<div class="stat-label">Cumulative Purchasing-Power Loss</div>' +
        '<div class="stat-value">' + lossPct.toFixed(1) + '%</div>' +
        '<div class="stat-sub">since ' + monthLabel(infl.cpiBaseDate) + ' · same CPI basket</div>';
      if (window.HeimdallFormat) window.HeimdallFormat.applyTooltip(lossCard.querySelector(".stat-label"), infl.purchasingPower.asOfDate, infl.purchasingPower.freq, DATA.generatedAtUtc);
    }
    el.appendChild(lossCard);
  }

  function renderCards() {
    var oEl = document.getElementById("group-observed");
    OBSERVED.forEach(function (m) { oEl.appendChild(renderMonthlyCard(m)); });
    var eEl = document.getElementById("group-expectations");
    EXPECTATIONS.forEach(function (m) { eEl.appendChild(renderDailyCard(m)); });
    var rEl = document.getElementById("group-robust");
    ROBUST.forEach(function (m) { rEl.appendChild(renderMonthlyCard(m)); });
    renderMoneyCards();
    renderHeimdallCards();
  }

  function pctFmt(v) { return v.toFixed(1) + "%"; }

  function renderCharts() {
    window.HeimdallCharts.create({
      canvasId: "chartCpi", rangeToggleId: "rangeToggle", csvButtonId: "chartCpiCsvBtn", csvFilename: "cpi_headline_vs_core_yoy",
      defaultRange: "5Y",
      series: [
        { key: "cpi", label: "Headline CPI YoY", color: "#f7931a", rows: DATA.series.cpiYoY },
        { key: "coreCpi", label: "Core CPI YoY", color: "#a89a7c", dash: [3, 4], rows: DATA.series.coreCpiYoY }
      ],
      yFormatter: pctFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartPce", rangeToggleId: "rangeToggle", csvButtonId: "chartPceCsvBtn", csvFilename: "pce_headline_vs_core_yoy",
      defaultRange: "5Y",
      series: [
        { key: "pce", label: "Headline PCE YoY", color: "#7f97ab", rows: DATA.series.pceYoY },
        { key: "corePce", label: "Core PCE YoY", color: "#a89a7c", dash: [3, 4], rows: DATA.series.corePceYoY }
      ],
      yFormatter: pctFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartBreakeven", rangeToggleId: "rangeToggle", csvButtonId: "chartBreakevenCsvBtn", csvFilename: "breakeven_inflation_5y_10y",
      defaultRange: "5Y",
      series: [
        { key: "be5", label: "5Y Breakeven", color: "#f7931a", rows: DATA.series.breakeven5y },
        { key: "be10", label: "10Y Breakeven", color: "#a89a7c", dash: [3, 4], rows: DATA.series.breakeven10y }
      ],
      yFormatter: pctFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartRobust", rangeToggleId: "rangeToggle", csvButtonId: "chartRobustCsvBtn", csvFilename: "median_trimmed_sticky_cpi",
      defaultRange: "5Y",
      series: [
        { key: "medianCpi", label: "Median CPI (ann. rate)", color: "#f7931a", rows: DATA.series.medianCpi },
        { key: "trimmedCpi", label: "Trimmed-Mean CPI (ann. rate)", color: "#7f97ab", dash: [3, 4], rows: DATA.series.trimmedCpi },
        { key: "coreStickyCpi", label: "Core Sticky CPI (YoY)", color: "#a89a7c", dash: [1, 3], rows: DATA.series.coreStickyCpi }
      ],
      yFormatter: pctFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartMoney", rangeToggleId: "rangeToggle", csvButtonId: "chartMoneyCsvBtn", csvFilename: "m2_yoy_vs_m2_over_nominal_gdp",
      defaultRange: "MAX",
      series: [
        { key: "m2YoY", label: "M2 YoY", color: "#f7931a", rows: DATA.series.m2YoY },
        { key: "m2OverNominalGdp", label: "M2 / Nominal GDP", color: "#7f97ab", dash: [3, 4], rows: DATA.series.m2OverNominalGdp }
      ],
      yFormatter: pctFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartPurchasingPower", rangeToggleId: "rangeToggle", csvButtonId: "chartPurchasingPowerCsvBtn", csvFilename: "purchasing_power_vs_price_level",
      defaultRange: "MAX",
      series: [
        { key: "purchasingPower", label: "Purchasing Power Index", color: "#7fae55", rows: DATA.series.purchasingPower },
        { key: "priceLevel", label: "Price Level Index", color: "#c0574a", dash: [3, 4], rows: DATA.series.priceLevel }
      ],
      yFormatter: function (v) { return v.toFixed(0); }
    });
  }

  if (!DATA) {
    document.getElementById("asOfNote").textContent = "no cached data — run fetch_macro_data.ps1";
    return;
  }

  renderCards();
  renderCharts();

  document.getElementById("asOfNote").textContent =
    "CPI " + monthLabel(DATA.inflation.cpiYoY.asOfDate) + " · PCE " + monthLabel(DATA.inflation.pceYoY.asOfDate);
  document.getElementById("generatedNote").textContent =
    "Data cached " + DATA.generatedAtUtc + " · source: FRED (St. Louis Fed), computed locally";
})();

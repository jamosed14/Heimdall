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
  // Spreads are small percentage-point deltas (0.48 = 48bp) - basis points is the unit
  // this desk actually thinks in, a "%" reading is just noise at this magnitude.
  function fmtBpsValue(v) {
    if (v === null || v === undefined) return "—";
    return Math.round(v * 100) + "bp";
  }
  function buildChip(tag, text, val) {
    if (text === null) return "";
    var cls = "chg-chip" + (val > 0 ? " positive" : val < 0 ? " negative" : "");
    return '<span class="' + cls + '"><span class="chg-tag">' + tag + "</span>" + text + "</span>";
  }

  var HEADLINE = [
    { key: "y3mo", label: "3M Treasury" },
    { key: "y2", label: "2Y Treasury" },
    { key: "y5", label: "5Y Treasury" },
    { key: "y10", label: "10Y Treasury" },
    { key: "y30", label: "30Y Treasury" },
    { key: "real10", label: "10Y Real Yield (TIPS)" }
  ];
  var SPREADS = [
    { key: "spread2s10", label: "2s10s Spread", unit: "bp" },
    { key: "spread3m10", label: "3M10Y Spread", unit: "bp" },
    { key: "spread5s30", label: "5s30s Spread", unit: "bp" }
  ];

  function renderCard(metric) {
    var stat = DATA.rates[metric.key];
    var card = document.createElement("div");
    card.className = "stat-card";
    if (!stat || stat.value === null) {
      card.innerHTML = '<div class="stat-label">' + metric.label + '</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
      return card;
    }
    var chips = buildChip("1D", fmtBpsChip(stat.chg1d), stat.chg1d) +
      buildChip("1W", fmtBpsChip(stat.chg1w), stat.chg1w) +
      buildChip("1M", fmtBpsChip(stat.chg1m), stat.chg1m);
    var valueText = metric.unit === "bp" ? fmtBpsValue(stat.value) : fmtPct(stat.value);
    card.innerHTML =
      '<div class="stat-label">' + metric.label + '</div>' +
      '<div class="stat-value">' + valueText + '</div>' +
      '<div class="chg-row">' + chips + '</div>';
    if (window.HeimdallFormat) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), stat.asOfDate, stat.freq, DATA.generatedAtUtc);
    }
    return card;
  }

  function renderCards() {
    var hEl = document.getElementById("group-headline");
    HEADLINE.forEach(function (m) { hEl.appendChild(renderCard(m)); });
    var sEl = document.getElementById("group-spreads");
    SPREADS.forEach(function (m) { sEl.appendChild(renderCard(m)); });
  }

  function renderYieldCurve() {
    var curve = DATA.yieldCurve;
    var order = curve.maturityOrder;
    var ctx = document.getElementById("curveChart").getContext("2d");

    function series(point, label, color, dash) {
      return {
        label: label,
        data: order.map(function (m) { return point[m]; }),
        borderColor: color,
        borderWidth: 3,
        borderDash: dash || [],
        pointRadius: 4,
        pointBackgroundColor: color,
        fill: false,
        tension: 0.15
      };
    }

    new Chart(ctx, {
      type: "line",
      data: {
        labels: order,
        datasets: [
          series(curve.now, "Now", "#f7931a"),
          series(curve.oneMonthAgo, "1M ago", "#a89a7c", [4, 4]),
          series(curve.oneYearAgo, "1Y ago", "#756a55", [2, 3])
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: {
            display: true,
            labels: { color: "#c7b9a0", boxWidth: 14, font: { size: 13 } }
          },
          tooltip: {
            backgroundColor: "#1c170f", borderColor: "#443a29", borderWidth: 1,
            titleColor: "#c7b9a0", bodyColor: "#f5f1e6", titleFont: { size: 13 }, bodyFont: { size: 13 }, padding: 10,
            callbacks: { label: function (item) { return item.dataset.label + ": " + fmtPct(item.parsed.y); } }
          }
        },
        scales: {
          x: { grid: { display: false }, ticks: { color: "#9c8f76", font: { size: 13 } }, border: { color: "#2c2620" } },
          y: {
            grid: { color: "#1a160f" }, border: { color: "#2c2620" },
            ticks: { color: "#9c8f76", font: { size: 13 }, callback: function (v) { return v.toFixed(1) + "%"; } }
          }
        }
      }
    });
  }

  function renderHistoryChart() {
    window.HeimdallCharts.create({
      canvasId: "yieldHistChart",
      rangeToggleId: "rangeToggle",
      csvButtonId: "yieldHistCsvBtn",
      csvFilename: "treasury_yields_2y_10y_30y",
      defaultRange: "5Y",
      series: [
        { key: "y10", label: "10Y", color: "#f7931a", rows: DATA.series.y10 },
        { key: "y2", label: "2Y", color: "#a89a7c", dash: [3, 4], rows: DATA.series.y2 },
        { key: "y30", label: "30Y", color: "#7f97ab", dash: [1, 3], rows: DATA.series.y30 }
      ],
      yFormatter: function (v) { return v.toFixed(1) + "%"; }
    });
  }

  // ---------- GLOBAL SOVEREIGN 10Y ----------
  var GLOBAL = window.GLOBAL_RATES_DATA;
  var GLOBAL_ORDER = ["US", "JP", "DE", "GB", "CA", "AU"];
  var GLOBAL_COLORS = { US: "#f7931a", JP: "#c0574a", DE: "#7f97ab", GB: "#7fae55", CA: "#a89a7c", AU: "#ab7d45" };

  // Two-letter country code -> flag emoji via Unicode regional indicator symbols (no image
  // assets needed - same technique used for currency/country badges elsewhere on the web).
  function flagEmoji(cc) {
    if (!cc || cc.length !== 2) return "";
    var base = 0x1F1E6 - 65; // regional indicator 'A' minus ASCII 'A'
    return String.fromCodePoint(cc.toUpperCase().charCodeAt(0) + base, cc.toUpperCase().charCodeAt(1) + base);
  }

  function renderGlobalRatesCards() {
    var el = document.getElementById("group-global-rates");
    if (!el) return; // section not present on this page build
    if (!GLOBAL || !GLOBAL.countries) {
      el.innerHTML = '<div class="stat-card"><div class="stat-label">Global Sovereign 10Y</div><div class="stat-value">—</div><div class="stat-sub">no cached data — run fetch_global_rates_data.ps1</div></div>';
      return;
    }
    GLOBAL_ORDER.forEach(function (cc) {
      var c = GLOBAL.countries[cc];
      var card = document.createElement("div");
      card.className = "stat-card";
      if (!c || c.value === null || c.value === undefined) {
        card.innerHTML = '<div class="stat-label">' + cc + '</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
        el.appendChild(card);
        return;
      }
      var chips = buildChip("1D", fmtBpsChip(c.chg1d / 100), c.chg1d) +
        buildChip("1W", fmtBpsChip(c.chg1w / 100), c.chg1w) +
        buildChip("1M", fmtBpsChip(c.chg1m / 100), c.chg1m);
      card.innerHTML =
        '<div class="stat-label">' + flagEmoji(cc) + " " + c.name + "</div>" +
        '<div class="stat-value">' + fmtPct(c.value) + "</div>" +
        '<div class="chg-row">' + chips + "</div>";
      if (window.HeimdallFormat) {
        window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), c.asOfDate, c.freq, GLOBAL.generatedAtUtc);
      }
      el.appendChild(card);
    });
  }

  function buildGlobalRatesLegend() {
    var el = document.getElementById("globalRatesLegend");
    if (!el) return;
    el.innerHTML = GLOBAL_ORDER.map(function (cc) {
      var name = (GLOBAL.countries[cc] && GLOBAL.countries[cc].name) || cc;
      return '<span class="legend-item"><span class="legend-dot" style="background:' + GLOBAL_COLORS[cc] + '"></span>' + flagEmoji(cc) + " " + name + "</span>";
    }).join("");
  }

  function renderGlobalRatesChart() {
    if (!GLOBAL || !GLOBAL.series) return;
    var canvas = document.getElementById("globalRatesChart");
    if (!canvas) return;

    var earliestDate = null;
    GLOBAL_ORDER.forEach(function (cc) {
      (GLOBAL.series[cc] || []).forEach(function (p) {
        if (!earliestDate || p.d < earliestDate) earliestDate = p.d;
      });
    });
    var sub = document.getElementById("globalRatesChartSub");
    if (sub && earliestDate) {
      sub.textContent = "Basis points, indexed to 0 at each country's first tracked observation (as far back as " + earliestDate + ") — shows repricing intensity independent of the starting yield level";
    }

    window.HeimdallCharts.create({
      canvasId: "globalRatesChart", rangeToggleId: "globalRatesRangeToggle", csvButtonId: "globalRatesCsvBtn",
      csvFilename: "global_sovereign_10y_cumulative_change", defaultRange: "1Y",
      ranges: { "1M": 30, "3M": 91, "1Y": 365, "MAX": null },
      series: GLOBAL_ORDER.map(function (cc) {
        var rows = (GLOBAL.series[cc] || []).slice().sort(function (a, b) { return a.d < b.d ? -1 : 1; });
        var base = rows.length ? rows[0].v : null;
        var idxRows = (base === null || base === undefined) ? [] : rows.map(function (p) { return { d: p.d, v: (p.v - base) * 100 }; });
        return { key: cc, label: cc, color: GLOBAL_COLORS[cc] || "#9c8f76", width: cc === "US" ? 3 : 2, rows: idxRows };
      }),
      yFormatter: function (v) { return (v > 0 ? "+" : "") + Math.round(v) + "bp"; }
    });
    buildGlobalRatesLegend();
  }

  function exportCurveCsv() {
    if (!window.HeimdallFormat) return;
    var curve = DATA.yieldCurve;
    var order = curve.maturityOrder;
    var rows = order.map(function (m) { return [m, curve.now[m], curve.oneMonthAgo[m], curve.oneYearAgo[m]]; });
    window.HeimdallFormat.downloadCsv("treasury_curve_snapshot.csv", ["maturity", "now_pct", "one_month_ago_pct", "one_year_ago_pct"], rows);
  }

  if (!DATA) {
    document.getElementById("asOfNote").textContent = "no cached data — run fetch_macro_data.ps1";
    return;
  }

  renderCards();
  renderYieldCurve();
  renderHistoryChart();
  // Independent of MACRO_DATA - a missing/failed global-rates fetch never blocks the rest of
  // this page.
  renderGlobalRatesCards();
  renderGlobalRatesChart();

  var curveCsvBtn = document.getElementById("curveCsvBtn");
  if (curveCsvBtn) curveCsvBtn.addEventListener("click", exportCurveCsv);

  document.getElementById("asOfNote").textContent = "latest print " + DATA.rates.y10.asOfDate;
  document.getElementById("generatedNote").textContent =
    "Data cached " + DATA.generatedAtUtc + " · source: FRED (St. Louis Fed), computed locally";
})();

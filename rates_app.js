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

  var HEADLINE = [
    { key: "y3mo", label: "3M Treasury" },
    { key: "y2", label: "2Y Treasury" },
    { key: "y5", label: "5Y Treasury" },
    { key: "y10", label: "10Y Treasury" },
    { key: "y30", label: "30Y Treasury" },
    { key: "real10", label: "10Y Real Yield (TIPS)" }
  ];
  var SPREADS = [
    { key: "spread2s10", label: "2s10s Spread" },
    { key: "spread3m10", label: "3M10Y Spread" },
    { key: "spread5s30", label: "5s30s Spread" }
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
    card.innerHTML =
      '<div class="stat-label">' + metric.label + '</div>' +
      '<div class="stat-value">' + fmtPct(stat.value) + '</div>' +
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

  var curveCsvBtn = document.getElementById("curveCsvBtn");
  if (curveCsvBtn) curveCsvBtn.addEventListener("click", exportCurveCsv);

  document.getElementById("asOfNote").textContent = "latest print " + DATA.rates.y10.asOfDate;
  document.getElementById("generatedNote").textContent =
    "Data cached " + DATA.generatedAtUtc + " · source: FRED (St. Louis Fed), computed locally";
})();

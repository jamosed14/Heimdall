(function () {
  var DATA = window.CREDIT_DATA;

  var OAS_TIP = "Option-adjusted spread over a Treasury spot curve. Wider spreads generally indicate greater compensation demanded for credit and liquidity risk.";

  function fmtBp(v) {
    if (v === null || v === undefined) return "—";
    return Math.round(v) + " bp";
  }
  function fmtBpChg(v) {
    if (v === null || v === undefined) return "—";
    var sign = v > 0 ? "+" : "";
    return sign + Math.round(v) + "bp";
  }
  function setSubClass(el, value) {
    // Widening (positive bp change) is not inherently "bad" the way a red number implies
    // elsewhere on Heimdall, but the color convention stays consistent site-wide: rising
    // spread = negative-colored, falling spread = positive-colored, since that's the reading
    // that matches every other tab's "red = deteriorating" convention.
    el.classList.remove("positive", "negative");
    if (value > 0) el.classList.add("negative");
    else if (value < 0) el.classList.add("positive");
  }
  function buildChip(tag, bpVal) {
    if (bpVal === null || bpVal === undefined) return "";
    var cls = "chg-chip" + (bpVal > 0 ? " negative" : bpVal < 0 ? " positive" : "");
    return '<span class="' + cls + '"><span class="chg-tag">' + tag + "</span>" + fmtBpChg(bpVal) + "</span>";
  }

  // ---------- Top cards ----------
  var CARD_DEFS = [
    { key: "ig", label: "IG OAS" },
    { key: "bbb", label: "BBB OAS" },
    { key: "hy", label: "HY OAS" },
    { key: "ccc", label: "CCC OAS" }
  ];

  function renderCards() {
    var el = document.getElementById("group-spreads");
    if (!DATA || !DATA.cards) {
      el.innerHTML = '<div class="stat-card"><div class="stat-label">Credit Spreads</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div></div>';
      return;
    }
    CARD_DEFS.forEach(function (def) {
      var c = DATA.cards[def.key];
      var card = document.createElement("div");
      card.className = "stat-card";
      if (!c || c.value === null) {
        card.innerHTML = '<div class="stat-label">' + def.label + '</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
        el.appendChild(card);
        return;
      }
      var chips = buildChip("1W", c.chg1w) + buildChip("1M", c.chg1m) + buildChip("3M", c.chg3m);
      var pctText = c.percentile === null ? "" :
        c.percentile + "th percentile since " + c.windowStart;
      card.innerHTML =
        '<div class="stat-label"><span class="info-tip" data-tip="' + OAS_TIP.replace(/"/g, "&quot;") + '">' + def.label + "</span></div>" +
        '<div class="stat-value">' + fmtBp(c.value) + "</div>" +
        '<div class="chg-row">' + chips + "</div>" +
        (pctText ? '<div class="stat-sub">' + pctText + "</div>" : "");
      if (window.HeimdallFormat) {
        window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), c.asOfDate, "daily", DATA.generatedAtUtc);
      }
      el.appendChild(card);
    });
  }

  // ---------- Quality curve ----------
  function renderQualityCurve() {
    var qc = DATA && DATA.qualityCurve;
    var canvas = document.getElementById("qualityCurveChart");
    if (!qc || !canvas) return;
    var labels = qc.order.map(function (k) { return qc.labels[k]; });
    function seriesFor(snapshot) { return qc.order.map(function (k) { return snapshot[k]; }); }

    var ctx = canvas.getContext("2d");
    var existing = Chart.getChart(canvas);
    if (existing) existing.destroy();

    new Chart(ctx, {
      type: "line",
      data: {
        labels: labels,
        datasets: [
          {
            label: "Current (" + qc.asOfDate + ")",
            data: seriesFor(qc.current),
            borderColor: "#f7931a",
            backgroundColor: "rgba(247,147,26,0.1)",
            borderWidth: 3,
            pointRadius: 4,
            pointBackgroundColor: "#f7931a",
            fill: true,
            tension: 0.1
          },
          {
            label: "1 month ago",
            data: seriesFor(qc.oneMonthAgo),
            borderColor: "#7f97ab",
            borderWidth: 2,
            borderDash: [4, 3],
            pointRadius: 3,
            pointBackgroundColor: "#7f97ab",
            fill: false,
            tension: 0.1
          },
          {
            label: "3 months ago",
            data: seriesFor(qc.threeMonthsAgo),
            borderColor: "#9c8f76",
            borderWidth: 2,
            borderDash: [2, 3],
            pointRadius: 3,
            pointBackgroundColor: "#9c8f76",
            fill: false,
            tension: 0.1
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: true, labels: { color: "#c7b9a0", boxWidth: 14, font: { size: 13 } } },
          tooltip: {
            backgroundColor: "#1c170f", borderColor: "#443a29", borderWidth: 1,
            titleColor: "#c7b9a0", bodyColor: "#f5f1e6", titleFont: { size: 13 }, bodyFont: { size: 13 }, padding: 10,
            callbacks: {
              label: function (item) {
                if (item.parsed.y === null || item.parsed.y === undefined) return null;
                return item.dataset.label + ": " + Math.round(item.parsed.y) + " bp";
              }
            }
          }
        },
        scales: {
          x: { grid: { display: false }, ticks: { color: "#9c8f76", font: { size: 13 } }, border: { color: "#2c2620" } },
          y: {
            grid: { color: "#1a160f" }, border: { color: "#2c2620" },
            ticks: { color: "#9c8f76", font: { size: 13 }, callback: function (v) { return Math.round(v) + "bp"; } }
          }
        }
      }
    });
  }

  // ---------- Risk dispersion ----------
  var DISPERSION_DEFS = [
    { key: "cccMinusBbb", label: "CCC − BBB", tip: "Difference between CCC-and-lower and BBB OAS. A wider gap indicates stronger differentiation between lower-quality and investment-grade borrowers." },
    { key: "hyMinusIg", label: "HY − IG", tip: "Difference between blended High Yield and Investment Grade OAS - the broadest single read on the IG/HY quality premium." },
    { key: "bMinusBbb", label: "B − BBB", tip: "Difference between Single-B and BBB OAS - isolates the step down across the investment-grade/high-yield boundary specifically." }
  ];

  function renderDispersion() {
    var el = document.getElementById("group-dispersion");
    var disp = DATA && DATA.dispersion;
    if (!disp) {
      el.innerHTML = '<div class="stat-card"><div class="stat-label">Risk Dispersion</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div></div>';
      return;
    }
    DISPERSION_DEFS.forEach(function (def) {
      var d = disp[def.key];
      var card = document.createElement("div");
      card.className = "stat-card";
      if (!d || d.value === null) {
        card.innerHTML = '<div class="stat-label">' + def.label + ' <span class="calc-badge">calc</span></div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
        el.appendChild(card);
        return;
      }
      var chips = buildChip("1W", d.chg1w) + buildChip("1M", d.chg1m) + buildChip("3M", d.chg3m);
      card.innerHTML =
        '<div class="stat-label"><span class="calc-badge info-tip" data-tip="' + def.tip.replace(/"/g, "&quot;") + '">' + def.label + '</span></div>' +
        '<div class="stat-value">' + fmtBp(d.value) + "</div>" +
        '<div class="chg-row">' + chips + "</div>";
      if (window.HeimdallFormat) {
        window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), d.asOfDate, "daily", DATA.generatedAtUtc);
      }
      el.appendChild(card);
    });
  }

  // ---------- History charts ----------
  function bpAxisFmt(v) { return Math.round(v) + "bp"; }

  function renderHistoryCharts() {
    if (!DATA || !DATA.series) return;
    window.HeimdallCharts.create({
      canvasId: "hyBbbChart", rangeToggleId: "historyRangeToggle", csvButtonId: "hyBbbCsvBtn",
      csvFilename: "credit_hy_bbb_oas", defaultRange: "MAX",
      series: [
        { key: "hy", label: "HY OAS", color: "#f7931a", fill: true, rows: DATA.series.hy },
        { key: "bbb", label: "BBB OAS", color: "#7f97ab", width: 2.5, dash: [3, 4], rows: DATA.series.bbb }
      ],
      yFormatter: bpAxisFmt
    });
    window.HeimdallCharts.create({
      canvasId: "cccChart", rangeToggleId: "historyRangeToggle", csvButtonId: "cccCsvBtn",
      csvFilename: "credit_ccc_oas", defaultRange: "MAX",
      series: [{ key: "ccc", label: "CCC & Lower OAS", color: "#c0574a", fill: true, rows: DATA.series.ccc }],
      yFormatter: bpAxisFmt
    });
  }

  if (!DATA) {
    document.getElementById("asOfNote").textContent = "no cached data — run fetch_credit_data.ps1";
    document.getElementById("generatedNote").textContent = "no cached data";
    return;
  }

  renderCards();
  renderQualityCurve();
  renderDispersion();
  renderHistoryCharts();

  document.getElementById("asOfNote").textContent = "latest print " + (DATA.cards.ig ? DATA.cards.ig.asOfDate : "—");
  document.getElementById("generatedNote").textContent =
    "Data cached " + DATA.generatedAtUtc + " · source: FRED (ICE BofA/ML indices), computed locally";
})();

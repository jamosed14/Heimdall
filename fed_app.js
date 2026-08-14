(function () {
  var DATA = window.MACRO_DATA;

  function fmtPct(v, digits) {
    if (v === null || v === undefined) return "—";
    return v.toFixed(digits === undefined ? 2 : digits) + "%";
  }
  function fmtUsdBillions(v) {
    if (v === null || v === undefined) return "—";
    var sign = v < 0 ? "-" : "";
    var abs = Math.abs(v);
    if (abs >= 1000) return sign + "$" + (abs / 1000).toFixed(2) + "T";
    if (abs >= 1) return sign + "$" + abs.toFixed(1) + "B";
    return sign + "$" + Math.round(abs * 1000) + "M";
  }
  function fmtBpsChip(delta) {
    if (delta === null || delta === undefined) return null;
    var bps = Math.round(delta * 100);
    return (bps > 0 ? "+" : "") + bps + "bp";
  }
  function fmtBpsDirect(bps) {
    if (bps === null || bps === undefined) return null;
    var r = Math.round(bps);
    return (r > 0 ? "+" : "") + r + "bp";
  }
  function fmtUsdChip(delta) {
    if (delta === null || delta === undefined) return null;
    return (delta > 0 ? "+" : "") + fmtUsdBillions(delta);
  }
  function buildChip(tag, text, val) {
    if (text === null) return "";
    var cls = "chg-chip" + (val > 0 ? " positive" : val < 0 ? " negative" : "");
    return '<span class="' + cls + '"><span class="chg-tag">' + tag + "</span>" + text + "</span>";
  }

  var POLICY = [
    { key: "fedFunds", label: "Effective Fed Funds Rate", type: "pct" },
    { key: "sofr", label: "SOFR", type: "pct" }
  ];
  var BALANCE = [
    { key: "fedAssets", label: "Fed Total Assets", type: "usd" },
    { key: "reserves", label: "Reserve Balances", type: "usd" },
    { key: "tga", label: "Treasury General Account", type: "usd" },
    { key: "rrp", label: "ON RRP", type: "usd", daily: true }
  ];

  function renderCard(metric) {
    var stat = DATA.fedLiquidity[metric.key];
    var card = document.createElement("div");
    card.className = "stat-card";
    if (!stat || stat.value === null) {
      card.innerHTML = '<div class="stat-label">' + metric.label + '</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
      return card;
    }
    var isUsd = metric.type === "usd";
    var fmtChip = isUsd ? fmtUsdChip : fmtBpsChip;
    var chips = "";
    if (metric.daily || stat.freq === "daily") chips += buildChip("1D", fmtChip(stat.chg1d), stat.chg1d);
    chips += buildChip("1W", fmtChip(stat.chg1w), stat.chg1w);
    chips += buildChip("1M", fmtChip(stat.chg1m), stat.chg1m);
    card.innerHTML =
      '<div class="stat-label">' + metric.label + '</div>' +
      '<div class="stat-value">' + (isUsd ? fmtUsdBillions(stat.value) : fmtPct(stat.value)) + '</div>' +
      '<div class="chg-row">' + chips + '</div>';
    if (window.HeimdallFormat) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), stat.asOfDate, stat.freq, DATA.generatedAtUtc);
    }
    return card;
  }

  function renderNetLiquidityCard() {
    var stat = DATA.fedLiquidity.netLiquidity;
    var el = document.getElementById("group-netliq");
    var card = document.createElement("div");
    card.className = "stat-card";
    if (!stat || stat.value === null) {
      card.innerHTML = '<div class="stat-label">Net Liquidity Proxy</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
      el.appendChild(card);
      return;
    }
    var chips = buildChip("1W", fmtUsdChip(stat.chg1w), stat.chg1w) + buildChip("1M", fmtUsdChip(stat.chg1m), stat.chg1m);
    var tip = "Fed Total Assets − Treasury General Account − ON RRP. A commonly used shorthand for dollar system liquidity — our calculation, not an official Federal Reserve statistic.";
    card.innerHTML =
      '<div class="stat-label"><span class="info-tip" data-tip="' + tip + '">Net Liquidity Proxy</span></div>' +
      '<div class="stat-value">' + fmtUsdBillions(stat.value) + '</div>' +
      '<div class="chg-row">' + chips + '</div>' +
      '<div class="stat-sub">= Fed Assets − TGA − ON RRP</div>';
    // The calc explanation above is the tooltip's existing content; the provenance note is
    // appended after it, per the standing tooltip-ordering convention.
    if (window.HeimdallFormat) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), stat.asOfDate, stat.freq, DATA.generatedAtUtc);
    }
    el.appendChild(card);
  }

  function renderCards() {
    var pEl = document.getElementById("group-policy");
    POLICY.forEach(function (m) { pEl.appendChild(renderCard(m)); });
    var bEl = document.getElementById("group-balance");
    BALANCE.forEach(function (m) { bEl.appendChild(renderCard(m)); });
    renderNetLiquidityCard();
  }

  // ---------- Fed Funds futures implied path ----------
  function fedPathCard(label, valueText, sub, chipHtml, obsDate, freq) {
    var card = document.createElement("div");
    card.className = "stat-card";
    card.innerHTML =
      '<div class="stat-label">' + label + '</div>' +
      '<div class="stat-value">' + valueText + '</div>' +
      (chipHtml ? '<div class="chg-row">' + chipHtml + '</div>' : '') +
      (sub ? '<div class="stat-sub">' + sub + '</div>' : '');
    if (window.HeimdallFormat && obsDate) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), obsDate, freq, DATA.generatedAtUtc);
    }
    return card;
  }

  function renderFedPathCards() {
    var fe = DATA.fedExpectations;
    var el = document.getElementById("group-fedpath");
    if (!fe || !fe.path || !fe.path.length) {
      el.appendChild(fedPathCard("Fed Funds Futures", "—", "data unavailable", null));
      return;
    }
    el.appendChild(fedPathCard(
      "Current EFFR",
      fmtPct(fe.currentEffr),
      null,
      null,
      fe.currentAsOf,
      "daily"
    ));
    // Curated spacing (~+1, +2, +4, +7, +10 months out) so the row stays scannable
    // instead of showing all 13 fetched contract months.
    var picks = [1, 2, 4, 7, 10].filter(function (i) { return i < fe.path.length; });
    picks.forEach(function (i) {
      var c = fe.path[i];
      var chip = buildChip("vs now", fmtBpsDirect(c.changeBps), c.changeBps);
      el.appendChild(fedPathCard(
        c.label.toUpperCase(),
        fmtPct(c.impliedRate),
        "futures " + c.futuresClose.toFixed(3),
        chip,
        c.asOfDate,
        "daily"
      ));
    });
  }

  function renderDotPlotCards() {
    var dp = (DATA.fedExpectations || {}).dotPlot;
    var el = document.getElementById("group-dotplot");
    if (!dp || !dp.projections || !dp.projections.length) {
      el.appendChild(fedPathCard("FOMC Dot Plot", "—", "data unavailable", null));
      return;
    }
    document.getElementById("dotPlotSub").textContent =
      "Median of FOMC participants' year-end federal funds rate projections (latest SEP, published " + dp.asOfDate + ") — the Fed's own stated expectation, conceptually distinct from market pricing above.";
    dp.projections.forEach(function (p) {
      el.appendChild(fedPathCard("End of " + p.year, fmtPct(p.medianRate), "FOMC median projection", null, dp.asOfDate, "daily"));
    });
    if (dp.longerRun !== null && dp.longerRun !== undefined) {
      el.appendChild(fedPathCard("Longer Run", fmtPct(dp.longerRun), "FOMC median, longer-run neutral rate", null, dp.asOfDate, "daily"));
    }
  }

  function renderFedPathChart() {
    var fe = DATA.fedExpectations;
    if (!fe || !fe.path || !fe.path.length) return;
    var labels = ["Now"].concat(fe.path.map(function (p) { return p.label; }));
    var implied = [fe.currentEffr].concat(fe.path.map(function (p) { return p.impliedRate; }));

    var dotMap = {};
    (fe.dotPlot.projections || []).forEach(function (p) { dotMap["Dec " + p.year] = p.medianRate; });
    var dotSeries = labels.map(function (l) { return dotMap.hasOwnProperty(l) ? dotMap[l] : null; });

    var ctx = document.getElementById("fedPathChart").getContext("2d");
    var existing = Chart.getChart(ctx.canvas);
    if (existing) existing.destroy();

    new Chart(ctx, {
      type: "line",
      data: {
        labels: labels,
        datasets: [
          {
            label: "Market-implied (Fed Funds futures)",
            data: implied,
            borderColor: "#f7931a",
            backgroundColor: "rgba(247,147,26,0.08)",
            borderWidth: 3,
            pointRadius: 4,
            pointBackgroundColor: "#f7931a",
            fill: true,
            tension: 0.15
          },
          {
            label: "FOMC dot plot median (where aligned)",
            data: dotSeries,
            borderColor: "#a89a7c",
            backgroundColor: "#a89a7c",
            borderWidth: 0,
            pointRadius: 6,
            pointStyle: "rectRot",
            pointBackgroundColor: "#a89a7c",
            showLine: false,
            spanGaps: false
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
                return item.dataset.label + ": " + fmtPct(item.parsed.y);
              }
            }
          }
        },
        scales: {
          x: { grid: { display: false }, ticks: { color: "#9c8f76", font: { size: 13 } }, border: { color: "#2c2620" } },
          y: {
            grid: { color: "#1a160f" }, border: { color: "#2c2620" },
            ticks: { color: "#9c8f76", font: { size: 13 }, callback: function (v) { return v.toFixed(2) + "%"; } }
          }
        }
      }
    });
  }

  function exportFedPathCsv() {
    var fe = DATA.fedExpectations;
    if (!fe || !fe.path) return;
    var rows = [["contract_month", "futures_close", "implied_effr_pct", "change_vs_current_effr_bps", "as_of_date"]];
    rows.push(["Current EFFR", "", fe.currentEffr, 0, fe.currentAsOf]);
    fe.path.forEach(function (c) {
      rows.push([c.label, c.futuresClose, c.impliedRate, c.changeBps, c.asOfDate]);
    });
    var csv = rows.map(function (r) { return r.join(","); }).join("\n");
    var blob = new Blob([csv], { type: "text/csv" });
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = "fed_funds_futures_implied_path_" + fe.currentAsOf + ".csv";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  function usdFmt(v) {
    var abs = Math.abs(v);
    if (abs >= 1000) return "$" + (v / 1000).toFixed(1) + "T";
    return "$" + v.toFixed(0) + "B";
  }

  function renderCharts() {
    window.HeimdallCharts.create({
      canvasId: "chartAssets", rangeToggleId: "rangeToggle", csvButtonId: "chartAssetsCsvBtn", csvFilename: "fed_total_assets",
      defaultRange: "MAX",
      series: [{ key: "fedAssets", label: "Fed Total Assets", color: "#f7931a", fill: true, rows: DATA.series.fedAssets }],
      yFormatter: usdFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartReserves", rangeToggleId: "rangeToggle", csvButtonId: "chartReservesCsvBtn", csvFilename: "reserve_balances",
      defaultRange: "MAX",
      series: [{ key: "reserves", label: "Reserve Balances", color: "#7f97ab", fill: true, rows: DATA.series.reserves }],
      yFormatter: usdFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartTgaRrp", rangeToggleId: "rangeToggle", csvButtonId: "chartTgaRrpCsvBtn", csvFilename: "tga_and_on_rrp",
      defaultRange: "MAX",
      series: [
        { key: "tga", label: "TGA", color: "#f7931a", rows: DATA.series.tga },
        { key: "rrp", label: "ON RRP", color: "#a89a7c", dash: [3, 4], rows: DATA.series.rrp }
      ],
      yFormatter: usdFmt
    });
    window.HeimdallCharts.create({
      canvasId: "chartNetLiq", rangeToggleId: "rangeToggle", csvButtonId: "chartNetLiqCsvBtn", csvFilename: "net_liquidity_proxy",
      defaultRange: "MAX",
      series: [{ key: "netLiquidity", label: "Net Liquidity Proxy", color: "#7fae55", fill: true, rows: DATA.series.netLiquidity }],
      yFormatter: usdFmt
    });
  }

  if (!DATA) {
    document.getElementById("asOfNote").textContent = "no cached data — run fetch_macro_data.ps1";
    return;
  }

  renderCards();
  renderFedPathCards();
  renderDotPlotCards();
  renderFedPathChart();
  renderCharts();

  var csvBtn = document.getElementById("fedPathCsvBtn");
  if (csvBtn) csvBtn.addEventListener("click", exportFedPathCsv);

  var latestDates = [DATA.fedLiquidity.fedFunds, DATA.fedLiquidity.fedAssets]
    .filter(Boolean).map(function (s) { return s.asOfDate; }).sort();
  document.getElementById("asOfNote").textContent = "latest print " + latestDates[latestDates.length - 1];
  document.getElementById("generatedNote").textContent =
    "Data cached " + DATA.generatedAtUtc + " · source: FRED (St. Louis Fed), computed locally";
})();

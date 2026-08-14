(function () {
  var DATA = window.MACRO_DATA;

  function fmtVal(v, digits) { return v === null || v === undefined ? "—" : v.toFixed(digits); }
  function fmtChgPct(chg, base, digits) {
    if (chg === null || chg === undefined || base === null) return null;
    var prior = base - chg;
    if (!prior) return null;
    var pct = (chg / prior) * 100;
    return (pct > 0 ? "+" : "") + pct.toFixed(digits) + "%";
  }
  function buildChip(tag, text, val) {
    if (text === null) return "";
    var cls = "chg-chip" + (val > 0 ? " positive" : val < 0 ? " negative" : "");
    return '<span class="' + cls + '"><span class="chg-tag">' + tag + "</span>" + text + "</span>";
  }

  var HEADLINE = [
    { key: "dxy", label: "DXY", digits: 2 },
    { key: "eurusd", label: "EUR/USD", digits: 4 },
    { key: "usdjpy", label: "USD/JPY", digits: 2 },
    { key: "gbpusd", label: "GBP/USD", digits: 4 },
    { key: "usdcny", label: "USD/CNY", digits: 4 }
  ];

  function renderCard(metric) {
    var stat = DATA.fx[metric.key];
    var card = document.createElement("div");
    card.className = "stat-card";
    if (!stat || stat.value === null) {
      card.innerHTML = '<div class="stat-label">' + metric.label + '</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
      return card;
    }
    var d = metric.digits;
    var chips =
      buildChip("1D", fmtChgPct(stat.chg1d, stat.value, 2), stat.chg1d) +
      buildChip("1M", fmtChgPct(stat.chg1m, stat.value, 2), stat.chg1m) +
      buildChip("YTD", fmtChgPct(stat.chgYtd, stat.value, 2), stat.chgYtd);
    card.innerHTML =
      '<div class="stat-label">' + metric.label + '</div>' +
      '<div class="stat-value">' + fmtVal(stat.value, d) + '</div>' +
      '<div class="chg-row">' + chips + '</div>';
    if (window.HeimdallFormat) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), stat.asOfDate, stat.freq, DATA.generatedAtUtc);
    }
    return card;
  }

  function renderCards() {
    var el = document.getElementById("group-fx");
    HEADLINE.forEach(function (m) { el.appendChild(renderCard(m)); });
  }

  function renderDxyChart() {
    window.HeimdallCharts.create({
      canvasId: "chartDxy",
      rangeToggleId: "dxyRangeToggle",
      csvButtonId: "dxyCsvBtn",
      csvFilename: "dxy_history",
      defaultRange: "MAX",
      ranges: { "1M": 30, "3M": 91, "1Y": 365, "3Y": 365 * 3, "MAX": null },
      series: [{ key: "dxy", label: "DXY", color: "#f7931a", fill: true, rows: DATA.series.dxy }],
      yFormatter: function (v) { return v.toFixed(1); }
    });
  }

  var PAIR_META = {
    eurusd: { label: "EUR/USD", digits: 4 },
    usdjpy: { label: "USD/JPY", digits: 2 }
  };
  var currentPair = "eurusd";

  function renderPairChart() {
    var meta = PAIR_META[currentPair];
    document.getElementById("pairTitle").textContent = meta.label;
    window.HeimdallCharts.create({
      canvasId: "chartPair",
      rangeToggleId: "pairRangeToggle",
      csvButtonId: "pairCsvBtn",
      csvFilename: currentPair + "_history",
      defaultRange: "MAX",
      ranges: { "1M": 30, "3M": 91, "1Y": 365, "3Y": 365 * 3, "MAX": null },
      series: [{ key: currentPair, label: meta.label, color: "#7f97ab", fill: true, rows: DATA.series[currentPair] }],
      yFormatter: function (v) { return v.toFixed(meta.digits); }
    });
  }

  function initPairPicker() {
    var el = document.getElementById("pairPicker");
    el.addEventListener("click", function (e) {
      var btn = e.target.closest("button");
      if (!btn) return;
      el.querySelectorAll("button").forEach(function (b) { b.classList.remove("active"); });
      btn.classList.add("active");
      currentPair = btn.dataset.pair;
      renderPairChart();
    });
  }

  if (!DATA) {
    document.getElementById("asOfNote").textContent = "no cached data — run fetch_macro_data.ps1";
    return;
  }

  renderCards();
  renderDxyChart();
  initPairPicker();
  renderPairChart();

  document.getElementById("asOfNote").textContent =
    "DXY as of " + DATA.fx.dxy.asOfDate + " · pairs as of " + DATA.fx.eurusd.asOfDate;
  document.getElementById("generatedNote").textContent =
    "Data cached " + DATA.generatedAtUtc + " · DXY: Yahoo/ICE · FX pairs: FRED, computed locally";
})();

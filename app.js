(function () {
  var DATA = window.BTC_DATA;

  function fmtUsd(n, opts) {
    if (n === null || n === undefined) return "—";
    opts = opts || {};
    var digits = opts.digits;
    if (digits === undefined) digits = n >= 1000 ? 0 : 2;
    return "$" + n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
  }

  function fmtPct(n, opts) {
    if (n === null || n === undefined) return "—";
    opts = opts || {};
    var sign = n > 0 ? "+" : "";
    return sign + n.toFixed(opts.digits === undefined ? 2 : opts.digits) + "%";
  }

  function fmtBps(n) {
    if (n === null || n === undefined) return "—";
    var bps = Math.round(n * 100);
    return (bps > 0 ? "+" : "") + bps + "bp";
  }

  function fmtUsdScale(n) {
    if (n === null || n === undefined) return "—";
    var sign = n < 0 ? "-" : "";
    var abs = Math.abs(n);
    if (abs >= 1e9) return sign + "$" + (abs / 1e9).toFixed(2) + "B";
    if (abs >= 1e6) return sign + "$" + (abs / 1e6).toFixed(1) + "M";
    if (abs >= 1e3) return sign + "$" + (abs / 1e3).toFixed(0) + "K";
    return sign + "$" + abs.toFixed(0);
  }

  function setSubClass(el, value) {
    el.classList.remove("positive", "negative");
    if (value > 0) el.classList.add("positive");
    else if (value < 0) el.classList.add("negative");
  }

  // Finds a card's .stat-label from its value element's id and applies the standardized
  // Observation/Heimdall-checked tooltip (appended after any existing tooltip content).
  function tagObs(valueElId, obsDate, freq) {
    if (!window.HeimdallFormat) return;
    var valueEl = document.getElementById(valueElId);
    if (!valueEl) return;
    var card = valueEl.closest(".stat-card") || valueEl.closest(".chart-header");
    var label = card ? (card.querySelector(".stat-label") || card.querySelector(".hero-label")) : null;
    window.HeimdallFormat.applyTooltip(label, obsDate, freq, DATA.generatedAtUtc);
  }

  // ---------- Static stat cards (from cached daily data) ----------
  function renderStats() {
    var s = DATA.stats;

    document.getElementById("asOfLabel").textContent = "as of " + DATA.asOfDate + " (UTC daily close)";
    document.getElementById("heroPrice").textContent = fmtUsd(s.price);
    document.getElementById("generatedNote").textContent =
      "Data cached " + DATA.generatedAtUtc + " · source: Coinbase daily close, computed locally";

    document.getElementById("statMA").textContent = fmtUsd(s.ma200w);
    var premiumEl = document.getElementById("statPremium");
    var premiumLabel = s.premiumPct === null ? "—" :
      (s.premiumPct >= 0 ? fmtPct(s.premiumPct) + " premium" : fmtPct(s.premiumPct) + " discount");
    premiumEl.textContent = premiumLabel;
    setSubClass(premiumEl, s.premiumPct || 0);

    document.getElementById("statATH").textContent = fmtUsd(s.athPrice);
    var ddEl = document.getElementById("statDrawdown");
    ddEl.textContent = fmtPct(s.drawdownPct) + " from ATH (" + s.athDate + ")";
    setSubClass(ddEl, s.drawdownPct);

    document.getElementById("statVol30").textContent = s.vol30dPct === null ? "—" : s.vol30dPct.toFixed(1) + "%";
    document.getElementById("statVol90").textContent = s.vol90dPct === null ? "—" : s.vol90dPct.toFixed(1) + "%";

    var basisEl = document.getElementById("statBasis");
    var basisSubEl = document.getElementById("statBasisSub");
    var b = s.cmeBasis;
    if (!b) {
      basisEl.textContent = "—";
      basisSubEl.textContent = "unavailable this refresh";
    } else {
      var basisDisplay = b.annualizedBasisPct !== null ? b.annualizedBasisPct : b.rawBasisPct;
      basisEl.textContent = fmtBps(basisDisplay) + (b.annualizedBasisPct !== null ? " ann." : " raw");
      setSubClass(basisEl, basisDisplay);
      var expiryNote = b.daysToExpiry !== null ? b.daysToExpiry + "d to expiry" : "";
      var niceLabel = b.contractLabel.replace(",", ", ");
      basisSubEl.textContent = "vs " + niceLabel + (expiryNote ? " · " + expiryNote : "");
    }

    tagObs("heroPrice", DATA.asOfDate, "daily");
    tagObs("statMA", DATA.asOfDate, "daily");
    tagObs("statATH", DATA.asOfDate, "daily");
    tagObs("statVol30", DATA.asOfDate, "daily");
    tagObs("statVol90", DATA.asOfDate, "daily");
    tagObs("statBasis", DATA.asOfDate, "daily");
  }

  // ---------- Chart (shared component) ----------
  function buildChart() {
    window.HeimdallCharts.create({
      canvasId: "btcChart",
      rangeToggleId: "rangeToggle",
      logToggleId: "logToggle",
      csvButtonId: "btcCsvBtn",
      csvFilename: "btc_price_200w_ma",
      defaultRange: "MAX",
      series: [
        {
          key: "price",
          label: "BTC Price",
          color: "#f7931a",
          fill: true,
          rows: DATA.series.map(function (r) { return { d: r.d, v: r.p }; })
        },
        {
          key: "ma200w",
          label: "200W MA",
          color: "#a89a7c",
          width: 2.5,
          dash: [3, 4],
          rows: DATA.series.map(function (r) { return { d: r.d, v: r.ma }; })
        }
      ],
      yFormatter: function (value) {
        if (value >= 1000) return "$" + Math.round(value / 1000) + "k";
        if (value >= 1) return "$" + Math.round(value);
        return "$" + value.toFixed(2);
      }
    });
  }

  // ---------- Live-derived premium/discount and drawdown ----------
  // The 200W MA and ATH are fixed reference levels from the cached Coinbase history (updated
  // nightly). The live BTC price - rendered by ticker.js into #liveBtcPrice - moves throughout
  // the day, so premium/discount and drawdown-from-ATH are recomputed against it live rather
  // than frozen at the last cache refresh. ticker.js itself is untouched; this only observes
  // the DOM it already renders.
  function parseLivePrice(text) {
    if (!text) return null;
    var n = parseFloat(text.replace(/[^0-9.\-]/g, ""));
    return (isFinite(n) && n > 0) ? n : null;
  }

  function updateLiveDerivedStats() {
    var livePrice = parseLivePrice(document.getElementById("liveBtcPrice") ? document.getElementById("liveBtcPrice").textContent : null);
    // No valid live price yet (still connecting, or ticker fetch failing) - fail stale:
    // leave whatever premium/drawdown value is already on screen untouched, never blank it.
    if (livePrice === null) return;

    var s = DATA.stats;
    if (s.ma200w) {
      var premiumEl = document.getElementById("statPremium");
      var pct = ((livePrice - s.ma200w) / s.ma200w) * 100;
      premiumEl.textContent = (pct >= 0 ? fmtPct(pct) + " premium" : fmtPct(pct) + " discount");
      setSubClass(premiumEl, pct);
    }
    if (s.athPrice) {
      var ddEl = document.getElementById("statDrawdown");
      var dd = ((livePrice - s.athPrice) / s.athPrice) * 100;
      // Live price can pass the cached ATH intraday, before the next nightly refresh updates
      // it - a positive "drawdown" would be nonsensical, so treat that as a fresh high (0%).
      if (dd > 0) dd = 0;
      ddEl.textContent = fmtPct(dd) + " from ATH (" + s.athDate + ")";
      setSubClass(ddEl, dd);
    }
  }

  var liveBtcMount = document.getElementById("liveBtcMount");
  if (liveBtcMount && window.MutationObserver) {
    new MutationObserver(updateLiveDerivedStats)
      .observe(liveBtcMount, { childList: true, subtree: true, characterData: true });
  }

  // ---------- Dealer Gamma Exposure (estimated, not observed) ----------
  var GEX_METHODOLOGY_TIP =
    "Estimated from Deribit's public BTC options open interest and mark IV using Black-Scholes " +
    "gamma. Follows the standard public-data convention (dealers assumed net long calls, net " +
    "short puts) used by SqueezeMetrics/SpotGamma-style calculators - not observed dealer " +
    "positioning, since no venue discloses actual dealer books.";

  function renderGex() {
    var G = window.GEX_DATA;
    var netEl = document.getElementById("gexNet");
    if (!netEl) return; // section not present on this page build
    if (!G) {
      document.getElementById("gexGeneratedNote").textContent = "no cached data — run fetch_gex_data.ps1";
      return;
    }

    netEl.textContent = fmtUsdScale(G.netGexUsd) + " / 1%";
    setSubClass(netEl, G.netGexUsd);

    var regimeEl = document.getElementById("gexRegime");
    if (G.netGexUsd > 0) {
      regimeEl.textContent = "dealers net long gamma (stabilizing)";
    } else if (G.netGexUsd < 0) {
      regimeEl.textContent = "dealers net short gamma (amplifying)";
    } else {
      regimeEl.textContent = "—";
    }

    document.getElementById("gexCallOi").textContent = G.totalCallOiBtc.toLocaleString("en-US", { maximumFractionDigits: 0 }) + " BTC";
    document.getElementById("gexPutOi").textContent = G.totalPutOiBtc.toLocaleString("en-US", { maximumFractionDigits: 0 }) + " BTC";
    document.getElementById("gexPcRatio").textContent = G.putCallOiRatio === null ? "—" : G.putCallOiRatio.toFixed(2);

    document.getElementById("gexGeneratedNote").textContent =
      "GEX snapshot cached " + G.generatedAtUtc + " · source: Deribit options chain (" + G.instrumentsUsed + " instruments), computed locally · estimate, not observed dealer positioning";

    // Pre-seed the calc-methodology tooltip on Net GEX's label before appending the standard
    // observation/checked note, same pattern as the Net Liquidity Proxy on the Fed tab.
    var netLabel = netEl.closest(".stat-card").querySelector(".stat-label");
    if (netLabel && window.HeimdallFormat) {
      var span = document.createElement("span");
      span.className = "info-tip";
      span.setAttribute("data-tip", GEX_METHODOLOGY_TIP);
      span.innerHTML = netLabel.innerHTML;
      netLabel.innerHTML = "";
      netLabel.appendChild(span);
      window.HeimdallFormat.applyTooltip(netLabel, G.asOfUtc.slice(0, 10), "daily", G.generatedAtUtc);
    }
  }

  function buildGexChart() {
    var G = window.GEX_DATA;
    var canvas = document.getElementById("gexChart");
    if (!canvas || !G) return;
    if (!G.byStrike || G.byStrike.length < 2) {
      var wrap = canvas.closest(".chart-wrap");
      if (wrap) wrap.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100%;color:var(--text-faint);font-size:13px;font-style:italic;">Insufficient data to render this chart</div>';
      return;
    }

    var labels = G.byStrike.map(function (p) { return p.k; });
    var values = G.byStrike.map(function (p) { return p.net; });
    var colors = values.map(function (v) { return v >= 0 ? "#7fae55" : "#c0574a"; });

    new Chart(canvas.getContext("2d"), {
      type: "bar",
      data: {
        labels: labels,
        datasets: [{ data: values, backgroundColor: colors, borderWidth: 0, barPercentage: 1.0, categoryPercentage: 0.9 }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: "#1c170f", borderColor: "#443a29", borderWidth: 1,
            titleColor: "#c7b9a0", bodyColor: "#f5f1e6", titleFont: { size: 13 }, bodyFont: { size: 13 }, padding: 10,
            callbacks: {
              title: function (items) { return "Strike $" + Number(items[0].label).toLocaleString("en-US"); },
              label: function (item) { return "Net GEX: " + fmtUsdScale(item.parsed.y) + " / 1%"; }
            }
          }
        },
        scales: {
          x: {
            grid: { display: false },
            border: { color: "#2c2620" },
            ticks: {
              color: "#9c8f76", font: { size: 11 }, maxTicksLimit: 12, autoSkip: true,
              callback: function (value) {
                var k = Number(labels[value]);
                return k >= 1000 ? "$" + Math.round(k / 1000) + "k" : "$" + k;
              }
            }
          },
          y: {
            grid: { color: "#1a160f" },
            border: { color: "#2c2620" },
            ticks: { color: "#9c8f76", font: { size: 12 }, callback: function (v) { return fmtUsdScale(v); } }
          }
        }
      }
    });
  }

  renderStats();
  buildChart();
  updateLiveDerivedStats();
  renderGex();
  buildGexChart();
  // Live ticker is handled by the shared ticker.js, included after this script.
})();

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
      basisEl.textContent = fmtPct(basisDisplay, { digits: 2 }) + (b.annualizedBasisPct !== null ? " ann." : " raw");
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

  renderStats();
  buildChart();
  updateLiveDerivedStats();
  // Live ticker is handled by the shared ticker.js, included after this script.
})();

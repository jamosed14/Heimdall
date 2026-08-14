// Shared live BTC ticker - Heimdall watching the one thing that never stops trading,
// regardless of which tab you're on. Every page includes this once and adds one mount
// point (<span id="liveBtcMount"></span>) in its ticker-bar; this builds the icon, dot,
// price, and 24h change into it and keeps polling. No-ops if the mount point is missing.
(function () {
  var ICON_SVG =
    '<svg class="btc-icon" viewBox="0 0 32 32" width="16" height="16" aria-hidden="true">' +
    '<circle cx="16" cy="16" r="16" fill="#f7931a"/>' +
    '<text x="16.5" y="22" font-family="Arial, sans-serif" font-size="19" font-weight="bold" fill="#0b0a09" text-anchor="middle">&#8383;</text>' +
    '</svg>';

  function fmtUsd(n) {
    if (n === null || n === undefined) return "—";
    return "$" + n.toLocaleString("en-US", { minimumFractionDigits: n >= 1000 ? 0 : 2, maximumFractionDigits: n >= 1000 ? 0 : 2 });
  }

  function poll() {
    var priceEl = document.getElementById("liveBtcPrice");
    var changeEl = document.getElementById("liveBtcChange");
    var noteEl = document.getElementById("liveBtcNote");
    if (!priceEl) return;

    fetch("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true")
      .then(function (r) { return r.json(); })
      .then(function (json) {
        var px = json.bitcoin.usd;
        var chg = json.bitcoin.usd_24h_change;
        priceEl.textContent = fmtUsd(px);
        if (changeEl) {
          changeEl.textContent = (chg >= 0 ? "+" : "") + chg.toFixed(2) + "% 24h";
          changeEl.classList.remove("positive", "negative");
          changeEl.classList.add(chg >= 0 ? "positive" : "negative");
        }
        if (noteEl) noteEl.textContent = "live · updated " + new Date().toLocaleTimeString();
      })
      .catch(function () {
        if (noteEl) noteEl.textContent = "live price unavailable";
      });
  }

  var mount = document.getElementById("liveBtcMount");
  if (mount) {
    mount.innerHTML =
      '<span class="live-price">' + ICON_SVG + '<span class="live-dot"></span><span id="liveBtcPrice">—</span></span>' +
      '<span class="change" id="liveBtcChange">—</span>';
  }

  poll();
  setInterval(poll, 45000);
})();

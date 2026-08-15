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
    return "$" + n.toLocaleString("en-US", { minimumFractionDigits: n >= 1000 ? 0 : 2, maximumFractionDigits: n >= 1000 ? 0 : 2 });
  }

  function isValidPrice(n) {
    return typeof n === "number" && isFinite(n) && n > 0;
  }

  var inFlight = false;

  function poll() {
    var priceEl = document.getElementById("liveBtcPrice");
    var changeEl = document.getElementById("liveBtcChange");
    var noteEl = document.getElementById("liveBtcNote");
    if (!priceEl) return;
    if (inFlight) return; // previous fetch still running - never stack overlapping requests

    inFlight = true;
    var controller = ("AbortController" in window) ? new AbortController() : null;
    var timeoutId = controller ? setTimeout(function () { controller.abort(); }, 10000) : null;

    fetch("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true", {
      signal: controller ? controller.signal : undefined
    })
      .then(function (r) {
        if (!r.ok) throw new Error("bad status " + r.status);
        return r.json();
      })
      .then(function (json) {
        var px = json && json.bitcoin && json.bitcoin.usd;
        var chg = json && json.bitcoin && json.bitcoin.usd_24h_change;

        // Only ever overwrite the displayed price with a validated, finite, positive
        // quote. Malformed/partial responses fall through untouched - the last known-good
        // price stays on screen exactly as if the fetch had failed outright.
        if (!isValidPrice(px)) throw new Error("invalid price payload");

        priceEl.textContent = fmtUsd(px);
        if (changeEl && typeof chg === "number" && isFinite(chg)) {
          changeEl.textContent = (chg >= 0 ? "+" : "") + chg.toFixed(2) + "% 24h";
          changeEl.classList.remove("positive", "negative");
          changeEl.classList.add(chg >= 0 ? "positive" : "negative");
        }
        if (noteEl) noteEl.textContent = "live · updated " + new Date().toLocaleTimeString();
      })
      .catch(function () {
        // Fetch failed, timed out, or returned malformed data - retain whatever price
        // is already on screen. Never blank, zero, or clear it here.
        if (noteEl) noteEl.textContent = "live price unavailable";
      })
      .finally(function () {
        if (timeoutId) clearTimeout(timeoutId);
        inFlight = false;
      });
  }

  var mount = document.getElementById("liveBtcMount");
  if (mount) {
    // Initial placeholder only, shown once before the first fetch ever resolves.
    // poll() never writes this dash back in once a real price has been displayed.
    mount.innerHTML =
      '<span class="live-price">' + ICON_SVG + '<span class="live-dot"></span><span id="liveBtcPrice">—</span></span>' +
      '<span class="change" id="liveBtcChange">—</span>';
  }

  poll();
  setInterval(poll, 45000);
})();

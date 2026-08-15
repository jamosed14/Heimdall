// Shared live BTC ticker - Heimdall watching the one thing that never stops trading,
// regardless of which tab you're on. Every page includes this once and adds one mount
// point (<span id="liveBtcMount"></span>) in its ticker-bar; this builds the icon, dot,
// and price into it and keeps polling. No-ops if the mount point is missing.
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

  var CACHE_KEY = "heimdallLastBtc";

  // Persist the last known-good quote across page loads. A full browser refresh wipes
  // all in-memory state, so without this a fresh load has nothing to show but the
  // placeholder dash while the first fetch is in flight or fails (e.g. rate-limited by
  // rapid repeated refreshes).
  function readCachedPrice() {
    try {
      var raw = window.localStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      var cached = JSON.parse(raw);
      if (!cached || !isValidPrice(cached.price)) return null;
      return cached;
    } catch (e) {
      return null;
    }
  }

  function writeCachedPrice(price) {
    try {
      window.localStorage.setItem(CACHE_KEY, JSON.stringify({
        price: price,
        ts: Date.now()
      }));
    } catch (e) {
      // localStorage unavailable/full/disabled - live display still works, just no
      // cross-reload memory this time.
    }
  }

  var inFlight = false;
  var BASE_INTERVAL = 45000;
  var MAX_INTERVAL = 5 * 60000; // cap backoff at 5 min so it still recovers on its own
  var consecutiveFailures = 0;
  var pollTimer = null;

  function scheduleNext() {
    var delay = consecutiveFailures > 0
      ? Math.min(BASE_INTERVAL * Math.pow(2, consecutiveFailures), MAX_INTERVAL)
      : BASE_INTERVAL;
    pollTimer = setTimeout(poll, delay);
  }

  function poll() {
    var priceEl = document.getElementById("liveBtcPrice");
    var noteEl = document.getElementById("liveBtcNote");
    if (!priceEl) return;
    if (inFlight) return; // previous fetch still running - never stack overlapping requests

    inFlight = true;
    var controller = ("AbortController" in window) ? new AbortController() : null;
    var timeoutId = controller ? setTimeout(function () { controller.abort(); }, 10000) : null;

    fetch("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd", {
      signal: controller ? controller.signal : undefined
    })
      .then(function (r) {
        if (!r.ok) throw new Error("bad status " + r.status);
        return r.json();
      })
      .then(function (json) {
        var px = json && json.bitcoin && json.bitcoin.usd;

        // Only ever overwrite the displayed price with a validated, finite, positive
        // quote. Malformed/partial responses fall through untouched - the last known-good
        // price stays on screen exactly as if the fetch had failed outright.
        if (!isValidPrice(px)) throw new Error("invalid price payload");

        priceEl.textContent = fmtUsd(px);
        if (noteEl) noteEl.textContent = "live · updated " + new Date().toLocaleTimeString();
        writeCachedPrice(px);
        consecutiveFailures = 0;
      })
      .catch(function () {
        // Fetch failed, timed out, or returned malformed data - retain whatever price
        // is already on screen. Never blank, zero, or clear it here.
        if (noteEl) noteEl.textContent = "live price unavailable";
        consecutiveFailures++;
      })
      .finally(function () {
        if (timeoutId) clearTimeout(timeoutId);
        inFlight = false;
        scheduleNext();
      });
  }

  var mount = document.getElementById("liveBtcMount");
  if (mount) {
    var cached = readCachedPrice();
    var initialPrice = cached ? fmtUsd(cached.price) : "—";
    mount.innerHTML =
      '<span class="live-price">' + ICON_SVG + '<span class="live-dot"></span><span id="liveBtcPrice">' + initialPrice + '</span></span>';

    // liveBtcNote is a pre-existing static element on some pages (not created here) -
    // only touch it if present, same as poll() already does.
    var noteEl0 = document.getElementById("liveBtcNote");
    if (noteEl0 && cached) noteEl0.textContent = "last known · " + new Date(cached.ts).toLocaleTimeString();
  }

  poll();
})();

(function () {
  var DATA = window.EQUITIES_DATA;

  function fmtUsd(n) {
    if (n === null || n === undefined) return "—";
    return "$" + n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function fmtPct(n) {
    if (n === null || n === undefined) return "—";
    var sign = n > 0 ? "+" : "";
    return sign + n.toFixed(2) + "%";
  }

  function setSubClass(el, value) {
    el.classList.remove("positive", "negative");
    if (value > 0) el.classList.add("positive");
    else if (value < 0) el.classList.add("negative");
  }

  var TICKERS_ORDER = ["MSTR", "STRC", "NVDA", "MSFT", "GOOGL", "AMZN", "META", "ORCL"];

  function renderCard(sym) {
    var t = DATA.tickers[sym];
    var card = document.createElement("div");
    card.className = "stat-card";
    if (!t) {
      card.innerHTML = '<div class="stat-label">' + sym + '</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div>';
      return card;
    }
    var wk52 = (t.wk52Lo !== null && t.wk52Hi !== null)
      ? "52wk " + fmtUsd(t.wk52Lo) + " – " + fmtUsd(t.wk52Hi)
      : "";
    card.innerHTML =
      '<div class="stat-label">' + sym + " · " + t.name + '</div>' +
      '<div class="stat-value">' + fmtUsd(t.price) + '</div>' +
      '<div class="stat-sub">' + fmtPct(t.chgPct) + (wk52 ? " · " + wk52 : "") + '</div>';
    var subEl = card.querySelector(".stat-sub");
    setSubClass(subEl, t.chgPct || 0);
    if (window.HeimdallFormat) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), t.asOfDate, "daily", DATA.generatedAtUtc);
    }
    return card;
  }

  function renderCards() {
    var btcGroup = document.getElementById("group-btc-proxy");
    var hyperGroup = document.getElementById("group-hyperscaler");
    TICKERS_ORDER.forEach(function (sym) {
      var t = DATA.tickers[sym];
      var target = (t && t.group === "hyperscaler") ? hyperGroup : btcGroup;
      target.appendChild(renderCard(sym));
    });
  }

  if (!DATA) {
    document.getElementById("asOfNote").textContent = "no cached data — run fetch_equities_data.ps1";
  } else {
    renderCards();
    var latestDate = null;
    TICKERS_ORDER.forEach(function (sym) {
      var t = DATA.tickers[sym];
      if (t && t.asOfDate && (!latestDate || t.asOfDate > latestDate)) latestDate = t.asOfDate;
    });
    document.getElementById("asOfNote").textContent = "latest print " + (latestDate || "—");
    document.getElementById("generatedNote").textContent =
      "Data cached " + DATA.generatedAtUtc + " · source: Yahoo Finance (unofficial), computed locally · informational only, not a licensed real-time feed";
  }
})();

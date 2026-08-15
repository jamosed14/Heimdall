// Shared nav bar. Each page sets window.HEIMDALL_PAGE to its own key before this script
// runs, and this renders the tab row into <div id="nav">. Adding a future tab (Credit,
// Energy, Strategy, ...) means editing this one array, not six HTML files.
(function () {
  var PAGES = [
    { key: "summary", label: "Summary", href: "Heimdall Catallaxy.html" },
    { key: "btc", label: "BTC", href: "BTC.html" },
    { key: "rates", label: "Rates", href: "Rates.html" },
    { key: "fed", label: "Fed & Liquidity", href: "Fed & Liquidity.html" },
    { key: "inflation", label: "Inflation", href: "Inflation.html" },
    { key: "fx", label: "Dollar & FX", href: "Dollar & FX.html" },
    { key: "energy", label: "Energy", href: "Energy.html" },
    { key: "ai", label: "AI Buildout", href: "AI.html" },
    { key: "credit", label: "Credit", href: "Credit.html" }
  ];

  var mount = document.getElementById("nav");
  if (!mount) return;
  var current = window.HEIMDALL_PAGE;

  mount.className = "nav-row";
  mount.innerHTML = PAGES.map(function (p) {
    var cls = p.key === current ? ' class="active"' : "";
    return '<a href="' + p.href.replace(/&/g, "&amp;") + '"' + cls + ">" + p.label + "</a>";
  }).join("");
})();

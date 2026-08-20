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
    { key: "credit", label: "Credit", href: "Credit.html" },
    { key: "energy", label: "Energy", href: "Energy.html" },
    { key: "ai", label: "AI Buildout", href: "AI.html" },
    { key: "equities", label: "Equities", href: "Equities.html" }
  ];

  var mount = document.getElementById("nav");
  if (!mount) return;
  var current = window.HEIMDALL_PAGE;

  mount.className = "nav-row";
  mount.innerHTML = PAGES.map(function (p) {
    var cls = p.key === current ? ' class="active"' : "";
    return '<a href="' + p.href.replace(/&/g, "&amp;") + '"' + cls + ">" + p.label + "</a>";
  }).join("");

  // ---------- Keyboard nav: Left/Right steps tabs, Home jumps Summary, letter keys jump tabs ----------
  // First letter of each tab, except Equities (E is taken by Energy) -> Q.
  var KEY_SHORTCUTS = {
    s: "summary", b: "btc", r: "rates", f: "fed", i: "inflation",
    d: "fx", c: "credit", e: "energy", a: "ai", q: "equities"
  };

  function isTypingTarget(el) {
    if (!el) return false;
    if (el.isContentEditable) return true;
    var tag = el.tagName;
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || tag === "BUTTON";
  }

  function goTo(key) {
    for (var i = 0; i < PAGES.length; i++) {
      if (PAGES[i].key === key) { window.location.href = PAGES[i].href; return; }
    }
  }

  document.addEventListener("keydown", function (e) {
    // Never hijack a browser/OS shortcut (Ctrl+B, Alt+Left, etc.) or a key repeat from
    // holding the key down, and never fire while focus is somewhere that key would
    // legitimately mean something else (typing in a field, activating a button).
    if (e.ctrlKey || e.metaKey || e.altKey || e.repeat) return;
    if (isTypingTarget(document.activeElement)) return;

    var idx = -1;
    for (var i = 0; i < PAGES.length; i++) { if (PAGES[i].key === current) { idx = i; break; } }

    if (e.key === "ArrowLeft") {
      if (idx > 0) { e.preventDefault(); window.location.href = PAGES[idx - 1].href; }
    } else if (e.key === "ArrowRight") {
      if (idx >= 0 && idx < PAGES.length - 1) { e.preventDefault(); window.location.href = PAGES[idx + 1].href; }
    } else if (e.key === "Home") {
      e.preventDefault();
      goTo("summary");
    } else {
      var target = KEY_SHORTCUTS[e.key.toLowerCase()];
      if (target) { e.preventDefault(); goTo(target); }
    }
  });
})();

// BTC tab - Network Hashrate section. Separate from app.js and fed by its own
// data/hashrate_data.js (fetch_hashrate_data.ps1, mempool.space), so a missing or failed
// hashrate fetch never affects the price/200W MA/GEX sections, and vice versa.
(function () {
  var H = window.HASHRATE_DATA;
  var grid = document.getElementById("group-hashrate");
  if (!grid) return;

  function fmtEh(v) {
    if (v === null || v === undefined || !isFinite(v)) return "—";
    if (v >= 100) return Math.round(v).toLocaleString("en-US") + " EH/s";
    if (v >= 1) return v.toFixed(1) + " EH/s";
    return v.toPrecision(2) + " EH/s";
  }
  // Axis labels: scale the unit instead of printing 6.0e-7 EH/s for 2009-era hashrate.
  var UNITS = [["EH/s", 1], ["PH/s", 1e-3], ["TH/s", 1e-6], ["GH/s", 1e-9], ["MH/s", 1e-12], ["kH/s", 1e-15]];
  function fmtAxis(v) {
    if (v === null || v === undefined || !isFinite(v) || v <= 0) return "";
    for (var i = 0; i < UNITS.length; i++) {
      if (v >= UNITS[i][1] || i === UNITS.length - 1) {
        var x = v / UNITS[i][1];
        return (x >= 100 ? Math.round(x).toLocaleString("en-US") : x >= 1 ? +x.toFixed(1) : +x.toPrecision(2)) + " " + UNITS[i][0];
      }
    }
  }
  function fmtPct(v) {
    if (v === null || v === undefined || !isFinite(v)) return "—";
    return (v > 0 ? "+" : "") + v.toFixed(2) + "%";
  }
  function fmtDate(iso) {
    if (!iso) return "—";
    var d = new Date(iso + "T00:00:00Z");
    return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  }
  function signClass(v) { return v > 0 ? " positive" : v < 0 ? " negative" : ""; }

  function card(label, value, sub, subVal, obsDate) {
    var el = document.createElement("div");
    el.className = "stat-card";
    el.innerHTML = '<div class="stat-label">' + label + '</div><div class="stat-value">' + value + "</div>" +
      (sub ? '<div class="stat-sub' + (subVal !== undefined ? signClass(subVal) : "") + '">' + sub + "</div>" : "");
    if (window.HeimdallFormat && obsDate) {
      window.HeimdallFormat.applyTooltip(el.querySelector(".stat-label"), obsDate, "daily", H.generatedAtUtc);
    }
    grid.appendChild(el);
  }

  if (!H || !H.stats || !H.series || !H.series.daily || !H.series.daily.length) {
    grid.innerHTML = '<div class="stat-card"><div class="stat-label">Network Hashrate</div><div class="stat-value">—</div><div class="stat-sub">no cached data — run fetch_hashrate_data.ps1</div></div>';
    return;
  }

  var S = H.stats;
  var athGap = (S.ath7dEh && S.hashrate7dEh) ? (S.hashrate7dEh / S.ath7dEh - 1) * 100 : null;
  card("Hashrate · 7D Avg", fmtEh(S.hashrate7dEh),
    athGap !== null && athGap < -0.05 ? fmtPct(athGap) + " vs 7D high (" + fmtDate(S.ath7dDate) + ")" : "at 7D-average high",
    athGap, S.asOfDate);
  card("Hashrate · 30D Change", fmtPct(S.chg30dPct), "7D avg vs 30 days earlier", S.chg30dPct, S.asOfDate);

  var A = S.lastAdjustment, N = H.nextAdjustment;
  if (A) {
    var sub = fmtDate(A.date) + " · block " + A.height.toLocaleString("en-US") + " · " + A.difficultyT.toFixed(1) + "T";
    if (N) sub += "<br>next est. " + fmtPct(N.estChangePct) + " ~" + fmtDate(N.estDate) + " (" + Math.round(N.progressPct) + "% through epoch)";
    card("Last Difficulty Adjustment", fmtPct(A.changePct), sub, undefined, A.date);
    var v = grid.lastChild.querySelector(".stat-value");
    if (v) v.className = "stat-value" + signClass(A.changePct);
  }

  // Trailing 7-day mean of the daily estimates, computed here so the data file only carries
  // the raw daily series. Only emitted once a full 7-day window exists.
  var daily = H.series.daily;
  var ma7 = [];
  var sum = 0;
  for (var i = 0; i < daily.length; i++) {
    sum += Number(daily[i].v);
    if (i >= 7) sum -= Number(daily[i - 7].v);
    if (i >= 6) ma7.push({ d: daily[i].d, v: sum / 7 });
  }

  if (window.HeimdallCharts) {
    window.HeimdallCharts.create({
      canvasId: "hashChart", rangeToggleId: "hashRangeToggle", csvButtonId: "hashCsvBtn",
      csvFilename: "btc_hashrate_7d_avg_ehs", defaultRange: "MAX",
      // Log by default: hashrate has grown ~15 orders of magnitude since 2009.
      logToggleId: "hashLogToggle", defaultLog: true,
      series: [{ key: "ma7", label: "Hashrate 7D avg", color: "#f7931a", width: 2, rows: ma7 }],
      yFormatter: fmtAxis
    });
  }

  var note = document.getElementById("hashGeneratedNote");
  if (note) {
    note.textContent = "Hashrate: mempool.space (daily estimates since 2009, 7D average computed locally) · cached " + H.generatedAtUtc +
      (H.sourceStatus && H.sourceStatus.mempool !== "ok" ? " · showing last good data (" + H.sourceStatus.mempool + ")" : "");
  }
})();

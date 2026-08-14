// Shared across every tab: the standardized "Observation / Heimdall checked" tooltip format,
// and a generic CSV download helper so export doesn't get reimplemented per page.
//
// Tooltip convention (do not break this): the observation+checked string is always appended
// to the END of any existing tooltip content, never prepended or interleaved. If a card
// already explains a calculation (e.g. Net Liquidity Proxy), that explanation stays first and
// the provenance note goes after it.
window.HeimdallFormat = (function () {
  function formatObsDate(dateStr, freq) {
    if (!dateStr) return "unknown";
    var d = new Date(dateStr + "T00:00:00Z");
    if (freq === "monthly") {
      return d.toLocaleString("en-US", { month: "short", year: "numeric", timeZone: "UTC" });
    }
    return d.toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  }

  function formatCheckedTime(isoUtc) {
    if (!isoUtc) return "unknown";
    var d = new Date(isoUtc);
    return d.toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
  }

  // existingTip: pass the card's current tooltip text (if any) - the new provenance note is
  // always appended after it, per the standing convention above.
  function obsTooltip(obsDate, freq, generatedAtUtc, existingTip) {
    var note = "Observation: " + formatObsDate(obsDate, freq) + " · Heimdall checked: " + formatCheckedTime(generatedAtUtc);
    if (existingTip) return existingTip + " " + note;
    return note;
  }

  // Wraps an existing label's inner HTML in an .info-tip span carrying the standardized
  // tooltip, preserving any data-tip content already on the element (appended per convention).
  function applyTooltip(el, obsDate, freq, generatedAtUtc) {
    if (!el) return;
    var existingSpan = el.querySelector(".info-tip");
    var existingTip = existingSpan ? existingSpan.getAttribute("data-tip") : null;
    var tip = obsTooltip(obsDate, freq, generatedAtUtc, existingTip);
    if (existingSpan) {
      existingSpan.setAttribute("data-tip", tip);
    } else {
      var span = document.createElement("span");
      span.className = "info-tip";
      span.setAttribute("data-tip", tip);
      span.innerHTML = el.innerHTML;
      el.innerHTML = "";
      el.appendChild(span);
    }
  }

  function toCsvValue(v) {
    if (v === null || v === undefined) return "";
    var s = String(v);
    if (s.indexOf(",") !== -1 || s.indexOf('"') !== -1) return '"' + s.replace(/"/g, '""') + '"';
    return s;
  }

  function downloadCsv(filename, headers, rows) {
    var lines = [headers.map(toCsvValue).join(",")].concat(
      rows.map(function (r) { return r.map(toCsvValue).join(","); })
    );
    var blob = new Blob([lines.join("\n")], { type: "text/csv" });
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  // Builds a wide CSV (one date column + one column per named series) from series that may be
  // on different native frequencies - e.g. daily RRP alongside weekly TGA - by unioning dates.
  function downloadSeriesCsv(filename, namedSeries) {
    // namedSeries: [{ name, rows: [{d, v}] }]
    var dateSet = {};
    namedSeries.forEach(function (s) {
      s.rows.forEach(function (r) { dateSet[r.d] = true; });
    });
    var dates = Object.keys(dateSet).sort();
    var maps = namedSeries.map(function (s) {
      var m = {};
      s.rows.forEach(function (r) { m[r.d] = r.v; });
      return m;
    });
    var headers = ["date"].concat(namedSeries.map(function (s) { return s.name; }));
    var rows = dates.map(function (d) {
      return [d].concat(maps.map(function (m) { return m.hasOwnProperty(d) ? m[d] : ""; }));
    });
    downloadCsv(filename, headers, rows);
  }

  return {
    formatObsDate: formatObsDate,
    formatCheckedTime: formatCheckedTime,
    obsTooltip: obsTooltip,
    applyTooltip: applyTooltip,
    downloadCsv: downloadCsv,
    downloadSeriesCsv: downloadSeriesCsv
  };
})();

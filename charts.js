// Shared time-series chart component used by every tab (BTC, Rates, Fed & Liquidity,
// Inflation, Dollar & FX). One implementation, reused everywhere a "value over time with a
// range toggle" chart is needed, instead of every tab rolling its own Chart.js config.
//
// Series points use {x: <ms-epoch>, y: <value>} so series of different native frequency
// (e.g. daily RRP alongside weekly TGA) can share one chart without being forced onto the
// same parallel-indexed label array.
window.HeimdallCharts = (function () {
  var DEFAULT_RANGES = { "1M": 30, "3M": 91, "1Y": 365, "3Y": 365 * 3, "5Y": 365 * 5, "MAX": null };

  if (window.Chart) {
    Chart.defaults.font.family = "'JetBrains Mono', Consolas, 'Cascadia Mono', monospace";
    Chart.defaults.font.size = 12;
  }

  function toPoints(rows, digits) {
    // rows: [{d: "YYYY-MM-DD", v: number}] -> [{x: msEpoch, y: number}]
    return rows
      .filter(function (r) { return r.v !== null && r.v !== undefined; })
      .map(function (r) { return { x: Date.parse(r.d + "T00:00:00Z"), y: r.v }; });
  }

  function filterPoints(points, rangeKey, ranges) {
    var days = ranges[rangeKey];
    if (!days || points.length === 0) return points;
    var lastX = points[points.length - 1].x;
    var cutoff = lastX - days * 86400000;
    return points.filter(function (p) { return p.x >= cutoff; });
  }

  function fmtAxisDate(ms) {
    var d = new Date(ms);
    return d.getUTCFullYear() + "-" + String(d.getUTCMonth() + 1).padStart(2, "0");
  }

  function create(opts) {
    // opts: {
    //   canvasId, series: [{key,label,color,dash,fill,rows:[{d,v}]}],
    //   rangeToggleId, logToggleId (optional), defaultRange ('MAX'),
    //   ranges (optional override), yFormatter(value), tooltipFormatter(label,value),
    //   zeroLine (bool) - draws a neutral reference line at y=0, useful for spreads
    // }
    var ranges = opts.ranges || DEFAULT_RANGES;
    var currentRange = opts.defaultRange || "MAX";
    var logScale = false;
    var chart = null;
    var canvas = document.getElementById(opts.canvasId);
    if (!canvas) return null;
    var ctx = canvas.getContext("2d");

    var seriesPoints = opts.series.map(function (s) { return toPoints(s.rows, 6); });

    function yFmt(v) { return opts.yFormatter ? opts.yFormatter(v) : String(v); }

    function build() {
      var datasets = opts.series.map(function (s, i) {
        return {
          label: s.label,
          data: filterPoints(seriesPoints[i], currentRange, ranges),
          borderColor: s.color,
          backgroundColor: s.fill ? s.color.replace(")", ",0.08)").replace("rgb", "rgba") : "transparent",
          borderWidth: s.width || 3,
          borderDash: s.dash || [],
          pointRadius: 0,
          pointHoverRadius: 4,
          pointHoverBackgroundColor: s.color,
          fill: !!s.fill,
          tension: 0.05,
          spanGaps: true
        };
      });

      var config = {
        type: "line",
        data: { datasets: datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          interaction: { mode: "index", intersect: false },
          plugins: {
            legend: { display: false },
            tooltip: {
              backgroundColor: "#1c170f",
              borderColor: "#443a29",
              borderWidth: 1,
              titleColor: "#c7b9a0",
              bodyColor: "#f5f1e6",
              titleFont: { size: 13 },
              bodyFont: { size: 13 },
              padding: 10,
              callbacks: {
                title: function (items) {
                  if (!items.length) return "";
                  return new Date(items[0].parsed.x).toISOString().slice(0, 10);
                },
                label: function (item) {
                  if (item.parsed.y === null || item.parsed.y === undefined) return null;
                  return item.dataset.label + ": " + yFmt(item.parsed.y);
                }
              }
            }
          },
          scales: {
            x: {
              type: "linear",
              bounds: "data",
              grid: { display: false },
              border: { color: "#2c2620" },
              ticks: {
                color: "#9c8f76",
                font: { size: 13 },
                maxTicksLimit: 8,
                autoSkip: true,
                // bounds:"data" clips the axis to the real data extent, which often leaves the
                // final tick interval shorter than the rest (evenly-spaced ticks minus whatever
                // partial step remains before the true data max) - without enough autoSkip
                // buffer, that compressed last gap renders two labels overlapping instead of
                // one being dropped. Default padding (3px) isn't enough for this monospace font.
                autoSkipPadding: 24,
                callback: function (value) { return fmtAxisDate(value); }
              }
            },
            y: (function () {
              var lastLabelLog = null;
              return {
                type: logScale ? "logarithmic" : "linear",
                bounds: "data",
                grid: { color: "#1a160f" },
                border: { color: "#2c2620" },
                ticks: {
                  color: "#9c8f76",
                  font: { size: 13 },
                  autoSkip: true,
                  maxTicksLimit: 8,
                  callback: function (value) {
                    if (logScale) {
                      var logV = Math.log10(Math.abs(value) || 1);
                      if (lastLabelLog !== null && Math.abs(logV - lastLabelLog) < 0.1) return null;
                      lastLabelLog = logV;
                    }
                    return yFmt(value);
                  }
                }
              };
            })()
          }
        }
      };

      if (chart) chart.destroy();
      var existing = Chart.getChart(canvas);
      if (existing) existing.destroy();
      chart = new Chart(ctx, config);
    }

    // Clones-and-replaces the node before binding so calling create() again on the same
    // element (e.g. the FX pair picker re-rendering its chart) never stacks duplicate
    // listeners from the previous call.
    function rebind(el) {
      var fresh = el.cloneNode(true);
      el.parentNode.replaceChild(fresh, el);
      return fresh;
    }

    if (opts.rangeToggleId) {
      var rangeEl = document.getElementById(opts.rangeToggleId);
      if (rangeEl) {
        rangeEl = rebind(rangeEl);
        rangeEl.addEventListener("click", function (e) {
          var btn = e.target.closest("button");
          if (!btn) return;
          rangeEl.querySelectorAll("button").forEach(function (b) { b.classList.remove("active"); });
          btn.classList.add("active");
          currentRange = btn.dataset.range;
          build();
        });
      }
    }

    if (opts.logToggleId) {
      var logBtn = document.getElementById(opts.logToggleId);
      if (logBtn) {
        logBtn = rebind(logBtn);
        logBtn.addEventListener("click", function () {
          logScale = !logScale;
          logBtn.classList.toggle("active", logScale);
          build();
        });
      }
    }

    if (opts.csvButtonId) {
      var csvBtn = document.getElementById(opts.csvButtonId);
      if (csvBtn && window.HeimdallFormat) {
        csvBtn = rebind(csvBtn);
        csvBtn.addEventListener("click", function () {
          // Exports the full underlying history, not just the currently selected range -
          // Heimdall's CSVs are meant to reconcile with the source, not with whatever's on screen.
          var namedSeries = opts.series.map(function (s) { return { name: s.key, rows: s.rows }; });
          var filename = (opts.csvFilename || opts.canvasId) + ".csv";
          window.HeimdallFormat.downloadSeriesCsv(filename, namedSeries);
        });
      }
    }

    build();
    return { rebuild: build };
  }

  return { create: create };
})();

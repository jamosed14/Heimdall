(function () {
  var DATA = window.AI_DATA;
  var MANUAL = window.AI_MANUAL || [];

  var COMPANY_COLORS = {
    MSFT: "#f7931a",
    GOOGL: "#7f97ab",
    AMZN: "#a89a7c",
    META: "#7fae55",
    ORCL: "#c0574a"
  };
  var COMPANY_ORDER = ["MSFT", "GOOGL", "AMZN", "META", "ORCL"];

  function fmtUsd(v, opts) {
    if (v === null || v === undefined) return "—";
    opts = opts || {};
    var sign = v < 0 ? "-" : "";
    var abs = Math.abs(v);
    if (abs >= 1e12) return sign + "$" + (abs / 1e12).toFixed(2) + "T";
    if (abs >= 1e9) return sign + "$" + (abs / 1e9).toFixed(opts.digits === undefined ? 1 : opts.digits) + "B";
    if (abs >= 1e6) return sign + "$" + (abs / 1e6).toFixed(1) + "M";
    return sign + "$" + abs.toFixed(0);
  }
  function fmtPct(v, digits) {
    if (v === null || v === undefined) return "—";
    var sign = v > 0 ? "+" : "";
    return sign + v.toFixed(digits === undefined ? 1 : digits) + "%";
  }
  function fmtPp(v, digits) {
    if (v === null || v === undefined) return "—";
    var sign = v > 0 ? "+" : "";
    return sign + v.toFixed(digits === undefined ? 1 : digits) + "pp";
  }
  function fmtIndex(v) {
    if (v === null || v === undefined) return "—";
    return v.toFixed(1);
  }
  function setSubClass(el, value) {
    el.classList.remove("positive", "negative");
    if (value > 0) el.classList.add("positive");
    else if (value < 0) el.classList.add("negative");
  }

  function statCard(container, label, valueText, subText, subValueForClass, obsDate, freq, tipHtml) {
    var card = document.createElement("div");
    card.className = "stat-card";
    var labelHtml = tipHtml
      ? '<span class="info-tip" data-tip="' + tipHtml.replace(/"/g, "&quot;") + '">' + label + "</span>"
      : label;
    card.innerHTML =
      '<div class="stat-label">' + labelHtml + "</div>" +
      '<div class="stat-value">' + valueText + "</div>" +
      (subText ? '<div class="stat-sub">' + subText + "</div>" : "");
    if (subText && subValueForClass !== undefined) {
      setSubClass(card.querySelector(".stat-sub"), subValueForClass);
    }
    if (window.HeimdallFormat && obsDate) {
      window.HeimdallFormat.applyTooltip(card.querySelector(".stat-label"), obsDate, freq, DATA.generatedAtUtc);
    }
    container.appendChild(card);
  }

  // ---------- CAPITAL ----------
  function renderCapital() {
    var el = document.getElementById("group-capital");
    var cap = DATA.capital;
    if (!cap || !cap.aggregate) {
      el.innerHTML = '<div class="stat-card"><div class="stat-label">Hyperscaler Capital</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div></div>';
      return;
    }
    var agg = cap.aggregate;
    var latestEnds = COMPANY_ORDER.map(function (t) { return cap.companies[t] && cap.companies[t].ttm.periodEnd; }).filter(Boolean).sort();
    var asOfLabel = latestEnds.length ? latestEnds[latestEnds.length - 1] : null;

    statCard(el, "Aggregate TTM Capex" + ' <span class="calc-badge">calc</span>',
      fmtUsd(agg.ttmCapex), agg.companyCount + " companies · sum of each company's own TTM",
      undefined, asOfLabel, "quarterly",
      "Sum of MSFT/GOOGL/AMZN/META/ORCL trailing-12-month capex, each ending on that company's own most recent reported quarter (not calendar-synchronized — see breakdown table below).");

    statCard(el, "Hyperscaler Capex YoY" + ' <span class="calc-badge">calc</span>',
      fmtPct(agg.ttmCapexYoYPct), "TTM capex vs TTM capex one year earlier",
      agg.ttmCapexYoYPct, asOfLabel, "quarterly");

    statCard(el, "Capex / Revenue" + ' <span class="calc-badge">calc</span>',
      agg.capexOverRevenuePct === null ? "—" : agg.capexOverRevenuePct.toFixed(1) + "%",
      "TTM capex ÷ TTM revenue, aggregate",
      undefined, asOfLabel, "quarterly");

    statCard(el, "Capex Growth − Revenue Growth" + ' <span class="calc-badge">calc</span>',
      agg.capexGrowthMinusRevenueGrowthPpt === null ? "—" : fmtPp(agg.capexGrowthMinusRevenueGrowthPpt),
      "TTM capex YoY minus TTM revenue YoY — positive means capex is outrunning revenue",
      agg.capexGrowthMinusRevenueGrowthPpt, asOfLabel, "quarterly");

    document.getElementById("capitalCalcNote").textContent =
      "Capex/revenue standalone-quarter figures are derived by Heimdall where a company files cash-flow amounts YTD-cumulative (standalone = this period minus the prior cumulative period within the same fiscal year). MSFT and ORCL have non-calendar fiscal years, so the aggregate above sums each company's own most recent quarter/TTM rather than assuming a shared calendar quarter exists. Full tag-by-tag sourcing is in the table below.";
  }

  // ---------- HYPERSCALER CREDIT (single-name CDS) ----------
  var CDS_METHODOLOGY_TIP =
    "ICE Clear Credit daily settlement price (clean price, 100bp fixed coupon), converted to a " +
    "conventional spread using the official ISDA CDS Standard Model converter (built and hosted " +
    "by IHS Markit in collaboration with S&P Global) - the actual production model, not a " +
    "Heimdall approximation. 40% recovery rate assumption, standard convention for senior " +
    "unsecured. Verified against independently-reported spread levels before shipping.";

  function renderCredit() {
    var el = document.getElementById("group-credit");
    if (!el) return; // section not present on this page build
    var CDS = window.CDS_DATA;
    if (!CDS || !CDS.tickers) {
      el.innerHTML = '<div class="stat-card"><div class="stat-label">Hyperscaler Credit</div><div class="stat-value">—</div><div class="stat-sub">no cached data — run fetch_cds_data.ps1</div></div>';
      return;
    }
    var order = Object.keys(CDS.tickers).sort(function (a, b) {
      return CDS.tickers[b].spreadBp - CDS.tickers[a].spreadBp;
    });
    order.forEach(function (ticker, i) {
      var t = CDS.tickers[ticker];
      var sub = t.cleanPrice.toFixed(2) + "% clean price · matures " + t.maturityDate;
      statCard(el, ticker + " 5Y CDS", t.spreadBp.toFixed(1) + " bp", sub,
        undefined, t.asOfDate, "daily", i === 0 ? CDS_METHODOLOGY_TIP : null);
    });
  }

  // NVDA isn't in COMPANY_COLORS (that map is capex-chart-specific and only covers the five
  // capex-reporting companies) - CDS charts cover all six hyperscalers, so extend it here rather
  // than touch the capex map's meaning.
  var CDS_COLORS = Object.assign({}, COMPANY_COLORS, { NVDA: "#ab7d45" });
  var CDS_CHART_RANGES = { "3M": 91, "6M": 182, "1Y": 365, "MAX": null };

  function cdsOrder(CDS) {
    return Object.keys(CDS.tickers).sort(function (a, b) {
      return CDS.tickers[b].spreadBp - CDS.tickers[a].spreadBp;
    });
  }

  function buildCdsLegend(elId, order) {
    var el = document.getElementById(elId);
    if (!el) return;
    el.innerHTML = order.map(function (ticker) {
      return '<span class="legend-item"><span class="legend-dot" style="background:' + (CDS_COLORS[ticker] || "#9c8f76") + '"></span>' + ticker + "</span>";
    }).join("");
  }

  function buildCdsHistoryCharts() {
    var CDS = window.CDS_DATA;
    if (!CDS || !CDS.tickers) return;
    var order = cdsOrder(CDS);

    var earliestDate = null;
    order.forEach(function (ticker) {
      (CDS.tickers[ticker].series || []).forEach(function (p) {
        if (!earliestDate || p.d < earliestDate) earliestDate = p.d;
      });
    });
    var sub = document.getElementById("cdsHistorySub");
    if (sub) {
      sub.textContent = earliestDate
        ? "Basis points, daily · tracking since " + earliestDate + " (no historical backfill available)"
        : "Basis points, daily";
    }

    window.HeimdallCharts.create({
      canvasId: "cdsHistoryChart", rangeToggleId: "cdsRangeToggle", csvButtonId: "cdsHistoryCsvBtn",
      csvFilename: "hyperscaler_cds_history", defaultRange: "MAX", ranges: CDS_CHART_RANGES,
      series: order.map(function (ticker) {
        return { key: ticker, label: ticker, color: CDS_COLORS[ticker] || "#9c8f76", width: ticker === "ORCL" ? 3 : 2, rows: CDS.tickers[ticker].series || [] };
      }),
      yFormatter: function (v) { return Math.round(v) + "bp"; }
    });
    buildCdsLegend("cdsLegend", order);

    // Indexed-to-100: each name normalized to its own first observation IN THE CURRENTLY
    // SELECTED WINDOW (rebasing happens inside charts.js, after range-filtering), so repricing
    // intensity is comparable across names regardless of starting spread level (e.g. MSFT at
    // 46bp widening 20% should read the same visual intensity as ORCL at 212bp widening 20%) -
    // and switching to "1M" shows that month's own repricing, not the whole history's.
    window.HeimdallCharts.create({
      canvasId: "cdsIndexedChart", rangeToggleId: "cdsRangeToggle", defaultRange: "MAX", ranges: CDS_CHART_RANGES,
      rebase: function (baseY, y) { return (y / baseY) * 100; },
      series: order.map(function (ticker) {
        return { key: ticker, label: ticker, color: CDS_COLORS[ticker] || "#9c8f76", width: ticker === "ORCL" ? 3 : 2, rows: CDS.tickers[ticker].series || [] };
      }),
      yFormatter: function (v) { return v.toFixed(0); }
    });
  }

  // Basis-point change from the latest observation to the nearest prior observation at least
  // `days` back. Returns null (not zero) when history doesn't reach back that far yet - a
  // missing window is not a flat window.
  function bpChangeAt(seriesAsc, days) {
    if (!seriesAsc || seriesAsc.length < 2) return null;
    var latest = seriesAsc[seriesAsc.length - 1];
    var targetMs = Date.parse(latest.d + "T00:00:00Z") - days * 86400000;
    for (var i = seriesAsc.length - 1; i >= 0; i--) {
      var ms = Date.parse(seriesAsc[i].d + "T00:00:00Z");
      if (ms <= targetMs) return latest.v - seriesAsc[i].v;
    }
    return null;
  }

  function ytdChangeBp(seriesAsc) {
    if (!seriesAsc || seriesAsc.length < 2) return null;
    var latest = seriesAsc[seriesAsc.length - 1];
    var jan1 = latest.d.slice(0, 4) + "-01-01";
    // Tracked history has to actually reach back to Jan 1 this year - otherwise there's no
    // real YTD baseline, only a partial-year one that would misleadingly look like a full YTD.
    if (seriesAsc[0].d > jan1) return null;
    for (var i = 0; i < seriesAsc.length; i++) {
      if (seriesAsc[i].d >= jan1) return latest.v - seriesAsc[i].v;
    }
    return null;
  }

  function cdsChangeCellStyle(bp) {
    if (bp === null || bp === undefined) return "";
    var mag = Math.min(Math.abs(bp) / 100, 1); // saturates at a 100bp move
    var alpha = (0.08 + mag * 0.30).toFixed(3);
    var rgb = bp > 0 ? "192,87,74" : "127,174,85"; // widening = red, tightening = green
    return ' style="background:rgba(' + rgb + "," + alpha + ')"';
  }

  function buildCdsChangeTable() {
    var CDS = window.CDS_DATA;
    var tbody = document.getElementById("cdsChangeBody");
    if (!tbody) return;
    if (!CDS || !CDS.tickers) {
      tbody.innerHTML = '<tr><td colspan="6">no cached data — run fetch_cds_data.ps1</td></tr>';
      return;
    }

    function fmtChg(bp) {
      if (bp === null || bp === undefined) return "—";
      return (bp > 0 ? "+" : "") + bp.toFixed(1) + "bp";
    }
    function chgClass(bp) {
      if (bp === null || bp === undefined) return "";
      return bp > 0 ? "negative" : bp < 0 ? "positive" : "";
    }

    tbody.innerHTML = cdsOrder(CDS).map(function (ticker) {
      var t = CDS.tickers[ticker];
      var seriesAsc = (t.series || []).slice().sort(function (a, b) { return a.d < b.d ? -1 : 1; });
      var w1 = bpChangeAt(seriesAsc, 7);
      var m1 = bpChangeAt(seriesAsc, 30);
      var m3 = bpChangeAt(seriesAsc, 91);
      var ytd = ytdChangeBp(seriesAsc);
      return "<tr>" +
        "<td>" + ticker + "</td>" +
        "<td>" + t.spreadBp.toFixed(1) + "bp</td>" +
        '<td class="' + chgClass(w1) + '"' + cdsChangeCellStyle(w1) + ">" + fmtChg(w1) + "</td>" +
        '<td class="' + chgClass(m1) + '"' + cdsChangeCellStyle(m1) + ">" + fmtChg(m1) + "</td>" +
        '<td class="' + chgClass(m3) + '"' + cdsChangeCellStyle(m3) + ">" + fmtChg(m3) + "</td>" +
        '<td class="' + chgClass(ytd) + '"' + cdsChangeCellStyle(ytd) + ">" + fmtChg(ytd) + "</td>" +
        "</tr>";
    }).join("");
  }

  // ---------- RECENT EARNINGS (all six - five capex-tracked hyperscalers + NVDA) ----------
  function fmtShortDate(d) {
    if (!d) return null;
    var dt = new Date(d + "T00:00:00Z");
    return dt.toLocaleString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  }

  function renderEarnings() {
    var el = document.getElementById("group-earnings");
    if (!el) return; // section not present on this page build
    var earn = DATA.earnings;
    if (!earn || !earn.companies) {
      el.innerHTML = '<div class="stat-card"><div class="stat-label">Recent Earnings</div><div class="stat-value">—</div><div class="stat-sub">no cached data — run fetch_ai_data.ps1</div></div>';
      return;
    }
    var tickers = Object.keys(earn.companies);
    // Most-recently-filed first, so a same-day release (e.g. NVDA's) surfaces at the top
    // instead of being buried in whatever order the fetch happened to resolve companies.
    tickers.sort(function (a, b) {
      var da = earn.companies[a].filedDate || "";
      var db = earn.companies[b].filedDate || "";
      return da < db ? 1 : da > db ? -1 : 0;
    });
    tickers.forEach(function (ticker) {
      var c = earn.companies[ticker];
      if (!c || c.revenue === null || c.revenue === undefined) {
        statCard(el, ticker, "—", "data unavailable");
        return;
      }
      var filedLabel = fmtShortDate(c.filedDate);
      var sub = fmtUsd(c.netIncome) + " net income" +
        (c.netMarginPct !== null && c.netMarginPct !== undefined ? " (" + c.netMarginPct.toFixed(1) + "% margin)" : "") +
        (c.revenueYoYPct !== null && c.revenueYoYPct !== undefined ? " · " + fmtPct(c.revenueYoYPct) + " rev YoY" : "");
      statCard(el, ticker + (filedLabel ? " · filed " + filedLabel : ""),
        fmtUsd(c.revenue), sub, c.netIncomeYoYPct, c.periodEnd, "quarterly",
        ticker === tickers[0] ? "Net margin is Heimdall-calculated (net income ÷ revenue), not a reported GAAP figure. Sorted by SEC filing date, most recent first." : null);
    });
  }

  function renderCompanyBreakdown() {
    var tbody = document.getElementById("companyBreakdownBody");
    var cap = DATA.capital;
    if (!cap || !cap.companies) return;
    var rows = "";
    COMPANY_ORDER.forEach(function (ticker) {
      var c = cap.companies[ticker];
      if (!c) return;
      var lq = c.latestQuarter;
      var capexOverRev = (lq.revenue && lq.revenue !== 0) ? (lq.capex / lq.revenue * 100) : null;
      var capexYoyCls = c.capexYoYPct > 0 ? "positive" : c.capexYoYPct < 0 ? "negative" : "";
      var revYoyCls = c.revenueYoYPct > 0 ? "positive" : c.revenueYoYPct < 0 ? "negative" : "";
      var tagNote = "rev: " + c.tags.revenue + (lq.revenueSource === "calc" ? " (calc)" : "") +
        " · capex: " + c.tags.capex + (lq.capexSource === "calc" ? " (calc)" : "");
      rows +=
        "<tr>" +
        "<td>" + c.name + " <span class=\"tag-note\">" + ticker + "</span><br><span class=\"tag-note\">" + tagNote + "</span></td>" +
        "<td>" + lq.periodEnd + "</td>" +
        "<td>" + fmtUsd(lq.revenue) + "</td>" +
        "<td>" + fmtUsd(lq.capex) + "</td>" +
        "<td>" + (capexOverRev === null ? "—" : capexOverRev.toFixed(1) + "%") + "</td>" +
        "<td class=\"" + capexYoyCls + "\">" + fmtPct(c.capexYoYPct) + "</td>" +
        "<td class=\"" + revYoyCls + "\">" + fmtPct(c.revenueYoYPct) + "</td>" +
        "</tr>";
    });
    tbody.innerHTML = rows;
  }

  function usdAxisFmt(v) {
    var abs = Math.abs(v);
    if (abs >= 1e12) return "$" + (v / 1e12).toFixed(1) + "T";
    if (abs >= 1e9) return "$" + (v / 1e9).toFixed(0) + "B";
    return "$" + v.toFixed(0);
  }

  function renderCapitalCharts() {
    var cap = DATA.capital;
    if (!cap) return;
    window.HeimdallCharts.create({
      canvasId: "aggCapexChart", rangeToggleId: "capitalRangeToggle", csvButtonId: "aggCapexCsvBtn",
      csvFilename: "ai_aggregate_ttm_capex", defaultRange: "MAX",
      series: [{ key: "aggregateTtmCapex", label: "Aggregate TTM Capex", color: "#f7931a", fill: true, rows: cap.series.aggregateTtmCapex }],
      yFormatter: usdAxisFmt
    });
    var companySeries = COMPANY_ORDER.map(function (ticker) {
      var c = cap.companies[ticker];
      if (!c) return null;
      return { key: ticker, label: ticker, color: COMPANY_COLORS[ticker], rows: c.series.capex };
    }).filter(Boolean);
    window.HeimdallCharts.create({
      canvasId: "companyCapexChart", rangeToggleId: "capitalRangeToggle", csvButtonId: "companyCapexCsvBtn",
      csvFilename: "ai_company_quarterly_capex", defaultRange: "MAX",
      series: companySeries,
      yFormatter: usdAxisFmt
    });
  }

  // ---------- COMPUTE ----------
  function renderCompute() {
    var el = document.getElementById("group-compute");
    var c = DATA.compute;
    if (!c) { el.innerHTML = '<div class="stat-card"><div class="stat-label">Compute</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div></div>'; return; }

    statCard(el, "Semiconductor Industrial Production", fmtIndex(c.semiIP.value),
      c.semiIPYoYPct.value === null ? "data unavailable" : fmtPct(c.semiIPYoYPct.value) + " YoY",
      c.semiIPYoYPct.value, c.semiIP.asOfDate, "monthly");

    statCard(el, "Semiconductor Capacity Utilization", c.semiCapUtil.value === null ? "—" : c.semiCapUtil.value.toFixed(1) + "%",
      c.semiCapUtilChgPp.value === null ? "data unavailable" : fmtPp(c.semiCapUtilChgPp.value) + " vs 1Y ago",
      c.semiCapUtilChgPp.value, c.semiCapUtil.asOfDate, "monthly",
      "Percentage-point change, not a percent change of the percentage.");

    window.HeimdallCharts.create({
      canvasId: "semiIPChart", rangeToggleId: "computeRangeToggle", csvButtonId: "semiIPCsvBtn",
      csvFilename: "semiconductor_industrial_production", defaultRange: "MAX",
      series: [{ key: "semiIP", label: "Semiconductor IP Index", color: "#f7931a", fill: true, rows: DATA.series.semiIP }],
      yFormatter: function (v) { return v.toFixed(0); }
    });
    window.HeimdallCharts.create({
      canvasId: "semiCapUtilChart", rangeToggleId: "computeRangeToggle", csvButtonId: "semiCapUtilCsvBtn",
      csvFilename: "semiconductor_capacity_utilization", defaultRange: "MAX",
      series: [{ key: "semiCapUtil", label: "Capacity Utilization", color: "#7f97ab", fill: true, rows: DATA.series.semiCapUtil }],
      yFormatter: function (v) { return v.toFixed(0) + "%"; }
    });
  }

  // ---------- POWER ----------
  function renderPower() {
    var el = document.getElementById("group-power");
    var p = DATA.power;
    if (!p) { el.innerHTML = '<div class="stat-card"><div class="stat-label">Electricity Demand</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div></div>'; return; }

    // EIA's "sales" field is in million kWh, which is numerically identical to GWh (1 million
    // kWh = 1 GWh) - no scaling needed there. TWh = million-kWh value / 1,000.
    statCard(el, "U.S. Electricity Demand", p.demand.value === null ? "—" : (p.demand.value / 1000).toFixed(0) + " TWh",
      p.demandYoYPct.value === null ? "data unavailable" : fmtPct(p.demandYoYPct.value) + " YoY",
      p.demandYoYPct.value, p.demand.asOfDate, "monthly",
      "Total U.S. retail electricity sales, all sectors — a macro/grid proxy, not AI-specific electricity demand.");

    statCard(el, "TTM Electricity Demand", p.demandTtm.value === null ? "—" : (p.demandTtm.value / 1000).toFixed(0) + " TWh",
      p.demandTtmYoYPct.value === null ? "data unavailable" : fmtPct(p.demandTtmYoYPct.value) + " YoY",
      p.demandTtmYoYPct.value, p.demandTtm.asOfDate, "monthly");

    window.HeimdallCharts.create({
      canvasId: "elecDemandChart", rangeToggleId: "powerRangeToggle", csvButtonId: "elecDemandCsvBtn",
      csvFilename: "us_electricity_demand", defaultRange: "MAX",
      series: [{ key: "elecDemand", label: "Electricity Demand", color: "#f7931a", fill: true, rows: DATA.series.elecDemand }],
      yFormatter: function (v) { return (v / 1000).toFixed(0) + " TWh"; }
    });
  }

  // ---------- INFRASTRUCTURE ----------
  function renderInfrastructure() {
    var el = document.getElementById("group-infrastructure");
    var i = DATA.infrastructure;
    if (!i) { el.innerHTML = '<div class="stat-card"><div class="stat-label">Infrastructure</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div></div>'; return; }

    statCard(el, "Transformer Cost Pressure", fmtIndex(i.transformerPPI.value),
      i.transformerPPIYoYPct.value === null ? "data unavailable" : fmtPct(i.transformerPPIYoYPct.value) + " YoY",
      i.transformerPPIYoYPct.value, i.transformerPPI.asOfDate, "monthly");

    statCard(el, "Electrical Equipment Production", fmtIndex(i.elecEquipProd.value),
      i.elecEquipProdYoYPct.value === null ? "data unavailable" : fmtPct(i.elecEquipProdYoYPct.value) + " YoY",
      i.elecEquipProdYoYPct.value, i.elecEquipProd.asOfDate, "monthly");

    window.HeimdallCharts.create({
      canvasId: "transformerChart", rangeToggleId: "infraRangeToggle", csvButtonId: "transformerCsvBtn",
      csvFilename: "transformer_ppi", defaultRange: "MAX",
      series: [{ key: "transformerPPI", label: "Transformer PPI", color: "#c0574a", fill: true, rows: DATA.series.transformerPPI }],
      yFormatter: function (v) { return v.toFixed(0); }
    });
    window.HeimdallCharts.create({
      canvasId: "elecEquipChart", rangeToggleId: "infraRangeToggle", csvButtonId: "elecEquipCsvBtn",
      csvFilename: "electrical_equipment_production", defaultRange: "MAX",
      series: [{ key: "elecEquipProd", label: "Electrical Equipment IP", color: "#7fae55", fill: true, rows: DATA.series.elecEquipProd }],
      yFormatter: function (v) { return v.toFixed(0); }
    });
  }

  // ---------- BROADER CAPITAL CYCLE ----------
  function renderCapitalCycle() {
    var el = document.getElementById("group-capitalcycle");
    var cc = DATA.capitalCycle;
    if (!cc) { el.innerHTML = '<div class="stat-card"><div class="stat-label">Info-Processing Investment</div><div class="stat-value">—</div><div class="stat-sub">data unavailable</div></div>'; return; }

    statCard(el, "Info-Processing Equipment & Software Investment", fmtUsd(cc.infoProcessingInvestment.value * 1e9),
      cc.infoProcessingInvestmentYoYPct.value === null ? "data unavailable" : fmtPct(cc.infoProcessingInvestmentYoYPct.value) + " YoY, SAAR",
      cc.infoProcessingInvestmentYoYPct.value, cc.infoProcessingInvestment.asOfDate, "quarterly",
      "U.S.-wide category AI capex sits inside, not an AI-specific figure.");

    window.HeimdallCharts.create({
      canvasId: "capCycleChart", rangeToggleId: "capCycleRangeToggle", csvButtonId: "capCycleCsvBtn",
      csvFilename: "info_processing_investment", defaultRange: "MAX",
      series: [{ key: "infoProcessingInvestment", label: "Info-Processing Investment", color: "#a89a7c", fill: true, rows: DATA.series.infoProcessingInvestment }],
      yFormatter: function (v) { return "$" + v.toFixed(0) + "B"; }
    });
  }

  // ---------- QUARTERLY WATCH ----------
  function renderQuarterlyWatch() {
    var el = document.getElementById("quarterlyWatchList");
    if (!MANUAL || MANUAL.length === 0) {
      el.innerHTML = '<div class="watch-empty">No manual entries yet — this section is updated a few times a year after reading actual filings/releases.</div>';
      return;
    }
    var sorted = MANUAL.slice().sort(function (a, b) { return a.date < b.date ? 1 : -1; });
    el.innerHTML = sorted.map(function (entry) {
      var textHtml = entry.text.replace(/&/g, "&amp;").replace(/</g, "&lt;");
      if (entry.sourceUrl) {
        textHtml += ' <a href="' + entry.sourceUrl.replace(/"/g, "&quot;") + '" target="_blank" rel="noopener">source</a>';
      }
      return '<div class="watch-entry"><span class="watch-date">' + entry.date + '</span><span class="watch-category">' + entry.category + '</span><span class="watch-text">' + textHtml + '</span></div>';
    }).join("");
  }

  // CDS_DATA is a separate cache from AI_DATA (different fetch script, different cadence) -
  // rendered independently so one being unavailable never blocks the other.
  renderCredit();
  buildCdsHistoryCharts();
  buildCdsChangeTable();

  if (!DATA) {
    document.getElementById("asOfNote").textContent = "no cached data — run fetch_ai_data.ps1";
    document.getElementById("generatedNote").textContent = "no cached data";
  } else {
    renderCapital();
    renderCompanyBreakdown();
    renderCapitalCharts();
    renderEarnings();
    renderCompute();
    renderPower();
    renderInfrastructure();
    renderCapitalCycle();

    var allAsOf = [];
    if (DATA.capital && DATA.capital.aggregate) {
      COMPANY_ORDER.forEach(function (t) {
        var c = DATA.capital.companies[t];
        if (c) allAsOf.push(c.ttm.periodEnd);
      });
    }
    if (DATA.compute) allAsOf.push(DATA.compute.semiIP.asOfDate);
    if (DATA.power) allAsOf.push(DATA.power.demand.asOfDate);
    allAsOf.sort();
    document.getElementById("asOfNote").textContent = allAsOf.length ? "latest print " + allAsOf[allAsOf.length - 1] : "—";
    document.getElementById("generatedNote").textContent =
      "Data cached " + DATA.generatedAtUtc + " · sources: SEC EDGAR XBRL, FRED, EIA, computed locally";
  }

  renderQuarterlyWatch();
})();

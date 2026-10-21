// Hand-maintained "Quarterly Watch" entries for the AI tab - management capex guidance,
// AI/data-center debt issuance, useful-life/depreciation-policy changes, and similar items
// without a clean automated source. NOT touched by fetch_ai_data.ps1 or refresh_all.ps1 -
// edit this file directly, a few times a year, after reading the actual filing/release.
// Each entry: { date: "YYYY-MM-DD", category: "guidance" | "financing" | "accounting" | "other",
//               text: "...", sourceUrl: "..." (optional) }
window.AI_MANUAL = [];

// Hand-maintained market-share figures for the AI tab's "Who Uses What" cards. No API exists for
// either - update by hand when a new edition is published (Menlo ~annually, Ramp monthly ~mid-month).
window.AI_MARKET_SHARE_MANUAL = {
  menlo: {
    openSourceSharePct: 11, priorYearPct: 19,
    asOf: "2025-12-09",
    sourceUrl: "https://menlovc.com/perspective/2025-the-state-of-generative-ai-in-the-enterprise/"
  },
  ramp: {
    anthropicPct: 43.8, openaiPct: 40.6, anyAiPct: 55.9,
    anthropicChgPts: 0.25, openaiChgPts: 1.12,
    dataMonth: "2026-09", asOf: "2026-10-14",
    sourceUrl: "https://ramp.com/data/ai-index-oct-2026"
  }
};

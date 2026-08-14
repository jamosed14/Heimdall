// Hand-maintained "Quarterly Watch" entries for the AI tab - management capex guidance,
// AI/data-center debt issuance, useful-life/depreciation-policy changes, and similar items
// without a clean automated source. NOT touched by fetch_ai_data.ps1 or refresh_all.ps1 -
// edit this file directly, a few times a year, after reading the actual filing/release.
// Each entry: { date: "YYYY-MM-DD", category: "guidance" | "financing" | "accounting" | "other",
//               text: "...", sourceUrl: "..." (optional) }
window.AI_MANUAL = [];

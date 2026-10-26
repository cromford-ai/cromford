// First run of a new fleet (BH-7977, BH-7939.3): does the fleet hold the three
// required accounts? The console's `/` shows the first-run screen in place of
// the Fleet list while one is missing and the gate row is on.
// Note: docs/notes/2026-10-25-BH-7977-first-run.md.
//
// GET /api/fleet/first-run  ONE statement. 200
//   {anthropic, github_app, telegram, more_ai, complete, gate}, all booleans.
//   anthropic   a non-revoked ai_accounts row of vendor 'claude'.
//   github_app  settings github_app.installed, trimmed, exactly '1'.
//   telegram    settings telegram.bot_present trimmed '1' AND telegram.chat_id
//               trimmed not empty.
//   more_ai     a non-revoked ai_accounts row of any other vendor. It never
//               changes `complete`.
//   complete    anthropic AND github_app AND telegram.
//   gate        settings first_run.gate trimmed '1'. No row reads false (the
//               code fallback of the row seeded by
//               schema.d/202610250546-bh-7977-first-run-gate.sql), so an
//               unseeded fleet never hides its list.
//   503 on a D1 error (d1Guarded); `ai_accounts schema not applied` when the
//   BH-7966 fragment is missing.
import { d1Guarded } from "../lib/http.js";

// The vendors that are "more AI accounts": every ai_accounts vendor but claude.
const MORE_AI_VENDORS = ["codex", "openrouter", "fireworks", "xai"];
const activeVendor = (v) => `EXISTS(SELECT 1 FROM ai_accounts WHERE vendor = '${v}' AND revoked_at IS NULL)`;

// Exported for the EXPLAIN test. Each ai_accounts EXISTS names ONE vendor, so
// ux_ai_accounts_vendor_label serves it as a SEARCH (vendor=?). One
// `vendor IN (…)` over four of the five vendors plans as a full SCAN at volume.
// The settings rows are PK lookups.
export const FIRST_RUN_SQL = `SELECT
  ${activeVendor("claude")} AS anthropic,
  EXISTS(SELECT 1 FROM settings WHERE key = 'github_app.installed' AND TRIM(value) = '1') AS github_app,
  (EXISTS(SELECT 1 FROM settings WHERE key = 'telegram.bot_present' AND TRIM(value) = '1')
   AND EXISTS(SELECT 1 FROM settings WHERE key = 'telegram.chat_id' AND TRIM(value) <> '')) AS telegram,
  (${MORE_AI_VENDORS.map(activeVendor).join("\n   OR ")}) AS more_ai,
  EXISTS(SELECT 1 FROM settings WHERE key = 'first_run.gate' AND TRIM(value) = '1') AS gate`;

// firstRunFrom(row) -> the answer. A missing row or column reads false.
export function firstRunFrom(row) {
  const r = row || {};
  const on = (k) => Number(r[k]) === 1;
  const out = {
    anthropic: on("anthropic"),
    github_app: on("github_app"),
    telegram: on("telegram"),
    more_ai: on("more_ai"),
    gate: on("gate"),
  };
  out.complete = out.anthropic && out.github_app && out.telegram;
  return out;
}

export const routes = [
  [
    "GET", "/api/fleet/first-run",
    ({ env }) => d1Guarded("ai_accounts", async () => {
      const row = await env.DB.prepare(FIRST_RUN_SQL).first();
      return new Response(JSON.stringify(firstRunFrom(row)), {
        status: 200,
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }),
  ],
];

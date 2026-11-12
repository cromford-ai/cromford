// approve-then-block — BH-9501 (BH-9441.4): the pure half of GET
// /api/metrics/approve-then-block. Param validation, the one SELECT, the fold.
// No clock: the route passes its `t` in.
//
// The metric: of the PRs with an in-build APPROVE in the window, the share
// whose LEAD review later answered BLOCK. Both facts are gate rows
// (pr_state_events, state='gate') written by lib/pr-gate-intake.js:
//   in-build APPROVE  builder_approved_sha IS NOT NULL (recordBuilderApprove,
//                     reason `builder-verdict:<job>`);
//   lead BLOCK        reason='verdict:lead' AND lead_verdict_word='BLOCK'
//                     (recordLeadVerdict; human and risk-tier verdicts carry
//                     `verdict:human` / `verdict:risk-tier` and do not count).
// Window = the `days` days that end at the end of `day` (UTC). cohort = the
// distinct (repo, number) with an APPROVE row in it; blocked = the cohort PRs
// with a lead BLOCK row in it whose id is above the PR's first APPROVE row id.
// Note: docs/notes/2026-11-11-BH-9501-approve-then-block.md.

import { dayWindow } from "./daily-digest/shape.js";

// A read limit, not a business number: the lane sends its knob
// DAILY_DIGEST_APPROVE_BLOCK_DAYS (catalog/lanes.d/daily-digest.knobs.d/DAILY_DIGEST_APPROVE_BLOCK_DAYS.json), and
// this only refuses a value that knob cannot hold. These are the knob file's
// min, max and default: change both together.
const DAYS = [1, 60, 14];
const DAY_MS = 86400000;

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// {win, from, to, days} or {error}. An explicit bad value is an error, never clamped.
export function parseParams(q, nowIso) {
  const win = dayWindow(q.get("day"), nowIso);
  if (!win) return { error: "day must be YYYY-MM-DD, a real date, not after today UTC" };
  const [lo, hi, def] = DAYS;
  let days = def;
  if (q.has("days")) {
    const v = q.get("days");
    if (!/^\d+$/.test(v) || Number(v) < lo || Number(v) > hi) return { error: `days must be an integer ${lo}..${hi}` };
    days = Number(v);
  }
  return { win, from: iso(Date.parse(win.to) - days * DAY_MS), to: win.to, days };
}

// ?1 from, ?2 to. String bounds are safe: every gate row's `at` is nowIso()
// (lib/http.js, lib/pr-gate.js recordGateEvent), the same second-precision
// YYYY-MM-DDTHH:MM:SSZ form as the bounds. One range read on idx_pr_state_events_state_at (state, at),
// grouped per PR; no correlated subquery.
export function approveBlockSql() {
  return `SELECT repo, number,
       MIN(CASE WHEN builder_approved_sha IS NOT NULL THEN id END) AS approve_id,
       MAX(CASE WHEN reason = 'verdict:lead' AND lead_verdict_word = 'BLOCK' THEN id END) AS block_id
  FROM pr_state_events
 WHERE state = 'gate' AND at >= ?1 AND at < ?2
 GROUP BY repo, number
HAVING approve_id IS NOT NULL`;
}

const share = (b, c) => (c > 0 ? b / c : null);

// rows from approveBlockSql -> {cohort, blocked, share, repos:[{repo, cohort, blocked, share}]},
// repos sorted by name.
export function foldApproveBlock(rows) {
  const per = new Map();
  let cohort = 0, blocked = 0;
  for (const r of rows) {
    if (r.approve_id === null || r.approve_id === undefined) continue;
    const hit = r.block_id !== null && r.block_id !== undefined && r.block_id > r.approve_id ? 1 : 0;
    const p = per.get(r.repo) || { repo: r.repo, cohort: 0, blocked: 0 };
    p.cohort += 1; p.blocked += hit;
    per.set(r.repo, p);
    cohort += 1; blocked += hit;
  }
  const repos = [...per.values()]
    .sort((a, b) => (a.repo < b.repo ? -1 : a.repo > b.repo ? 1 : 0))
    .map((p) => ({ ...p, share: share(p.blocked, p.cohort) }));
  return { cohort, blocked, share: share(blocked, cohort), repos };
}

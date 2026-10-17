// mc-budget routes — a daily counter per (project, day, kind) for the merge
// conductor's metered spends (BH-6887, BH-6881.3). The first kind is
// `rereview`: the operator-set daily re-review cap (MC_REREVIEW_DAILY_CAP)
// spends one unit before each re-review it buys. Shell client:
// mc_day_budget_take / mc_day_budget_give in bin/lib/mc/locks.sh. Contract:
// docs/notes/2026-10-17-BH-6887-mc-lease-budget.md.
//
// POST /api/mc-budget/take {project, kind, limit}: makes sure the row exists,
// then spends with ONE statement, `spent = spent + 1 ... AND spent < limit`.
// Two takes of the last unit at the same time: one wins. 200
// {granted:true, day, spent}, or 200 {granted:false, day} when the day's
// limit is spent. A denial is a 200, so an outage never reads as a full cap.
// POST /api/mc-budget/give {project, kind, day}: hands one unit back (a spawn
// that did not happen). It never goes below 0. 200 {given:true|false}.
//
// The day is the worker's UTC date; a box never sends a time. The take
// answers the day, and a give sends it back, so a give after midnight refunds
// the row the take spent.

import { d1Guarded, json } from "../lib/http.js";
import { laneName, strictInt } from "../lib/core.js";

// Exported so tests/lib/mc-budget.bh-6887.mjs explains the exact statements.
export const SEED_SQL = "INSERT OR IGNORE INTO mc_budget (project,day,kind,spent) VALUES (?1,?2,?3,0)";
export const SPEND_SQL = "UPDATE mc_budget SET spent = spent + 1 WHERE project=?1 AND day=?2 AND kind=?3 AND spent < ?4 RETURNING spent";
export const GIVE_SQL = "UPDATE mc_budget SET spent = spent - 1 WHERE project=?1 AND day=?2 AND kind=?3 AND spent > 0";

const KIND_RE = /^[a-z][a-z0-9_-]{0,31}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const LIMIT_MAX = 1000000;

// The validated request, or { error } for a 400. Runs before any statement.
function parse(raw, { limit, day }) {
  const body = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const project = laneName(body.project);
  if (!project) return { error: "project is required and must match [A-Za-z0-9._-]{1,64}" };
  const kind = typeof body.kind === "string" && KIND_RE.test(body.kind) ? body.kind : "";
  if (!kind) return { error: "kind is required and must match [a-z][a-z0-9_-]{0,31}" };
  const out = { project, kind };
  if (limit) {
    const n = typeof body.limit === "string" || typeof body.limit === "number" ? strictInt(body.limit) : null;
    if (n === null || n < 1 || n > LIMIT_MAX) return { error: `limit must be an integer in 1..${LIMIT_MAX}` };
    out.limit = n;
  }
  if (day) {
    if (typeof body.day !== "string" || !DAY_RE.test(body.day)) return { error: "day must be YYYY-MM-DD" };
    out.day = body.day;
  }
  return out;
}

export const routes = [
  [
    "POST", "/api/mc-budget/take",
    ({ env, t, body }) => d1Guarded("mc_budget", async () => {
      const q = parse(body, { limit: true, day: false });
      if (q.error) return json(400, { error: q.error });
      const day = t.slice(0, 10);
      await env.DB.prepare(SEED_SQL).bind(q.project, day, q.kind).run();
      const row = await env.DB.prepare(SPEND_SQL).bind(q.project, day, q.kind, q.limit).first();
      if (row) return json(200, { granted: true, day, spent: Number(row.spent) });
      return json(200, { granted: false, day });
    }),
  ],
  [
    "POST", "/api/mc-budget/give",
    ({ env, body }) => d1Guarded("mc_budget", async () => {
      const q = parse(body, { limit: false, day: true });
      if (q.error) return json(400, { error: q.error });
      const r = await env.DB.prepare(GIVE_SQL).bind(q.project, q.day, q.kind).run();
      return json(200, { given: ((r && r.meta && Number(r.meta.changes)) || 0) > 0 });
    }),
  ],
];

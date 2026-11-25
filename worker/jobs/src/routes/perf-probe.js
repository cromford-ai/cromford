// perf probe result routes — BH-9786. bin/perf-probe.sh (the daily hub lane)
// loads each route of a project row in catalog/perf-probe.d/ and writes one
// row per route per day here, through `jobs-client.sh perf-probe results-put`
// (schema.d/202611241027-bh-9786-perf-probe.sql).
//
// POST /api/perf-probe/results {project, day, kind, run_key, rows:[...]}
//   rows[i] = {route, ttfb_ms, total_ms, bytes, status, over_budget, outcome,
//   loads, breaks}. outcome is pass | fail | unmeasured, or
//   failed-then-recovered (BH-9792: the warm-up lane bin/perf-probe-warm.sh
//   writes it for a post-deploy load that broke and passed on its one retry).
//   One D1 batch of upserts on the natural key (project, route,
//   day, kind, run_key): a rerun on the same day replaces the row. At most
//   perf_probe.rows_max rows per call. 200 {written: <n>}.
// A bad field is 400 {error: <field>}; a bad row field is
// 400 {error: "rows[<i>].<field>"}.
// Note: docs/notes/2026-11-17-BH-9786-perf-probe.md.

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";

const PROJECT_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const RUN_KEY_RE = /^[A-Za-z0-9._:-]{1,80}$/;
const KINDS = new Set(["daily", "post-deploy"]);
const OUTCOMES = new Set(["pass", "fail", "unmeasured", "failed-then-recovered"]);
// Field cap: input validation of one text cell, not a limit on work, so it is
// not a settings row (the same rule as suite-quarantine.js).
const ROUTE_MAX = 500;
// Fallback of the settings row perf_probe.rows_max (the most rows one POST may
// carry; seeded in schema.d/202611241027-bh-9786-perf-probe.sql).
const ROWS_MAX_DEFAULT = 500;
const INT_FIELDS = ["ttfb_ms", "total_ms", "bytes", "status", "loads", "breaks"];

export const SQL = {
  upsert: `INSERT INTO perf_probe_results
             (project, route, day, kind, run_key, ttfb_ms, total_ms, bytes, status, over_budget, outcome, loads, breaks, created_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
           ON CONFLICT(project, route, day, kind, run_key) DO UPDATE SET
             ttfb_ms=excluded.ttfb_ms, total_ms=excluded.total_ms, bytes=excluded.bytes,
             status=excluded.status, over_budget=excluded.over_budget, outcome=excluded.outcome,
             loads=excluded.loads, breaks=excluded.breaks, created_at=excluded.created_at`,
};

const bad = (field) => json(400, { error: field });
const okInt = (v) => v === null || v === undefined || (Number.isInteger(v) && v >= 0);

// rowError(r) — the first bad field of one row, or null.
function rowError(r) {
  if (!r || typeof r !== "object" || Array.isArray(r)) return "route";
  if (typeof r.route !== "string" || !r.route.startsWith("/") || r.route.length > ROUTE_MAX) return "route";
  for (const f of INT_FIELDS) if (!okInt(r[f])) return f;
  if (r.status !== null && r.status !== undefined && r.status > 999) return "status";
  if (r.over_budget !== 0 && r.over_budget !== 1) return "over_budget";
  if (!OUTCOMES.has(r.outcome)) return "outcome";
  return null;
}

const orNull = (v) => (v === undefined ? null : v);

export const routes = [
  [
    "POST", "/api/perf-probe/results",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return bad("project");
      if (typeof b.day !== "string" || !DAY_RE.test(b.day)) return bad("day");
      if (!KINDS.has(b.kind)) return bad("kind");
      if (typeof b.run_key !== "string" || !RUN_KEY_RE.test(b.run_key)) return bad("run_key");
      if (!Array.isArray(b.rows) || b.rows.length === 0) return bad("rows");
      for (let i = 0; i < b.rows.length; i++) {
        const e = rowError(b.rows[i]);
        if (e) return bad(`rows[${i}].${e}`);
      }
      return d1Guarded("perf_probe_results", async () => {
        const { byKey } = await settingsRows(env);
        const max = intSetting(byKey, "perf_probe.rows_max", ROWS_MAX_DEFAULT, 1, 100000);
        if (b.rows.length > max) return bad("rows");
        const stmts = b.rows.map((r) => env.DB.prepare(SQL.upsert).bind(
          b.project, r.route, b.day, b.kind, b.run_key,
          orNull(r.ttfb_ms), orNull(r.total_ms), orNull(r.bytes), orNull(r.status),
          r.over_budget, r.outcome, orNull(r.loads), orNull(r.breaks), t));
        await env.DB.batch(stmts);
        return json(200, { written: stmts.length });
      });
    },
  ],
];

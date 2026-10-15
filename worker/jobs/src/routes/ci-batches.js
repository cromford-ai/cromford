// ci-batches routes — BH-4971 (BH-4964.3): the per-merge-queue-batch CI cost
// ledger, one row per Harness CI run_id.
//
// Writer: bin/ci-batch-ledger.sh (hub lane), one PUT per batch run it reads.
// It GETs the window first and skips every run_id already here, so the ledger
// IS the lane's skip-set: the GET's `truncated` must be honest, or the lane
// would re-read recorded runs every tick. A run whose GitHub run_attempt is past
// the row's run_attempt is NOT skipped: the re-run is read and the row rewritten.
//
// The table ships in schema.sql, which bin/harness-sync.sh applies before
// `wrangler deploy`; both handlers are d1Guarded so an unapplied table answers
// 503 "ci_batches schema not applied", never a bodiless 500.

import { json, d1Guarded } from "../lib/http.js";
import { str } from "../lib/core.js";

const INTS = ["selected", "total", "run_attempt", "wall_s", "billed_min"];
const STRS = ["head_ref", "head_sha", "mode", "escalation", "conclusion", "started_at", "completed_at"];
const STR_MAX = 512;
const LIMIT_DEFAULT = 500;
const LIMIT_MAX = 5000;
const SINCE_RE = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}Z)?$/;
const COLS = ["run_id", "repo", "head_ref", "head_sha", "mode", "selected", "total", "escalation",
  "conclusion", "run_attempt", "started_at", "completed_at", "wall_s", "billed_min", "as_of"];

// null for absent, the number for a non-negative safe integer, undefined for
// anything else: a bad count is refused, never clamped to something plausible.
function countOrNull(v) {
  if (v === undefined || v === null) return null;
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : undefined;
}

export const routes = [
  [
    "PUT", "/api/ci-batches",
    async ({ env, t, body }) => {
      const runId = body.run_id;
      if (typeof runId !== "number" || !Number.isSafeInteger(runId) || runId <= 0) {
        return json(400, { error: "run_id required" });
      }
      const repo = str(body.repo, 256);
      if (!repo) return json(400, { error: "repo required" });
      const row = { run_id: runId, repo };
      for (const f of INTS) {
        const n = countOrNull(body[f]);
        if (n === undefined) return json(400, { error: `${f} must be null or a non-negative integer` });
        row[f] = n;
      }
      for (const f of STRS) row[f] = str(body[f], STR_MAX);
      row.as_of = t;
      const binds = COLS.map((c) => row[c]);
      return d1Guarded("ci_batches", async () => {
        // sql-ident-ok: COLS is a module const column list, mapped to ?N placeholders
        await env.DB.prepare(
          `INSERT INTO ci_batches (${COLS.join(", ")}) VALUES (${COLS.map((_, i) => `?${i + 1}`).join(", ")}) ` +
          `ON CONFLICT(run_id) DO UPDATE SET ${COLS.slice(1).map((c) => `${c}=excluded.${c}`).join(", ")}`
        ).bind(...binds).run();
        return json(200, { ok: true, row });
      });
    },
  ],

  [
    "GET", "/api/ci-batches",
    async ({ env, url, t }) => {
      const repo = str(url.searchParams.get("repo"), 256);
      const since = url.searchParams.get("since");
      if (since !== null && since !== "" && !SINCE_RE.test(since)) {
        return json(400, { error: "since must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ" });
      }
      const rawLimit = url.searchParams.get("limit");
      let limit = LIMIT_DEFAULT;
      if (rawLimit !== null) {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : NaN;
        if (!(limit >= 1 && limit <= LIMIT_MAX)) return json(400, { error: `limit must be 1..${LIMIT_MAX}` });
      }
      const where = [];
      const binds = [];
      if (repo) { binds.push(repo); where.push(`repo=?${binds.length}`); }
      if (since) { binds.push(since); where.push(`completed_at >= ?${binds.length}`); }
      // One past the limit, so `truncated` says the list really was cut.
      binds.push(limit + 1);
      return d1Guarded("ci_batches", async () => {
        // sql-ident-ok: COLS is a module const column list; where holds literal column=?N clauses
        const res = await env.DB.prepare(
          `SELECT ${COLS.join(", ")} FROM ci_batches${where.length ? ` WHERE ${where.join(" AND ")}` : ""} ` +
          `ORDER BY completed_at DESC, run_id DESC LIMIT ?${binds.length}`
        ).bind(...binds).all();
        const rows = res.results || [];
        return json(200, { rows: rows.slice(0, limit), as_of: t, truncated: rows.length > limit });
      });
    },
  ],
];

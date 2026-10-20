// cost-breakdown route — BH-3557: the fleet's spend, grouped and labelled.
//
// Before this, the only place an operator saw "the fleet spent $1,259 today"
// was the $ TODAY cell of every lane that declared no cost stage (lanes.js now
// reports null there). This is where that number moves to: one grouped read
// over cost_rows by up to two dimensions, plus a leaf read of the rows
// themselves, so every group on /costs drills down to the calls behind it.
//
// NOTHING THE CALLER SENDS IS INTERPOLATED INTO SQL. A dimension or filter
// name is checked against DIMS, and statements() picks its SQL text from
// literals in this file; every value, the rows limit included, is a bind.

import { json, overloadGuardedRoute } from "../lib/http.js";
import { str, ensureColumns } from "../lib/core.js";
import { readHistory, mergeRows, mergeAggregate, mergeGroups } from "../lib/archive-read.js";

// dimension -> max filter length. Lengths match the POST's str() caps.
const DIMS = { project: 128, stage: 64, runner: 64, model: 256, billing_mode: 32, ticket: 128 };
const ISO_RE = /^\d{4}-\d{2}-\d{2}T[0-9:.]+Z$/;
// Read limits, not business parameters (same footing as account-usage's LIMITS).
const GROUP_CAP = 500;
const ROWS_MAX = 500;
const ROWS_DEFAULT = 200;

// The aggregate columns. One line of literals, so the sql-command-injection
// check can vouch for every use (its shape (a), BH-4501).
const AGG_COLS = ["COUNT(*) AS calls", "SUM(cost_usd) AS usd", "SUM(CASE WHEN billing_mode='metered' THEN COALESCE(cost_usd,0) ELSE 0 END) AS cash_usd", "SUM(CASE WHEN billing_mode='subscription' THEN COALESCE(cost_usd,0) ELSE 0 END) AS equiv_usd", "SUM(cost_usd IS NULL) AS unpriced_calls"];
// For the ticket grouping the bare run_id/job_id/project come from the row
// holding MAX(ts): SQLite's documented bare-column rule for a query with
// exactly one min()/max() aggregate (D1 is SQLite). That is what lets a
// ticket link to its newest build or job.
const LAST_COLS = ", run_id AS last_run_id, job_id AS last_job_id, project AS last_project";
// How two stores' AGG_COLS rows combine (lib/archive-read.js mergeAggregate).
const AGG_SPEC = { calls: "sum", usd: "sum", cash_usd: "sum", equiv_usd: "sum", unpriced_calls: "sum" };
const desc = (a, b) => (a < b ? 1 : a > b ? -1 : 0);
// SQLite's ORDER BY for TEXT: NULL first, then by code unit.
const asc = (a, b) => (a === b ? 0 : a === null ? -1 : b === null ? 1 : a < b ? -1 : 1);

// statements(q, since, until, group, limit) — the three reads and their binds.
// The SQL text is literals only: each filter clause and each grouped column is
// a literal picked by a switch on a DIMS key (`group` is checked against DIMS
// before this runs). Every value the caller sends is an anonymous `?` bind, in
// the order its `?` appears. The sql-command-injection check proves it per line.
// A filter present and EMPTY (`project=`) means "has none": NULL, '' and
// whitespace all fold into one null group below, so a `(no project)` group
// drills down through exactly that clause. `total` is a second statement, so
// the total is exact even when the groups are capped. No comment line may sit
// between `where = []` and its last use: the check reads comment lines as
// unseen lines and stops vouching for the array.
function statements(q, since, until, group, limit) {
  const binds = [since, until];
  const where = [];
  where.push("ts >= ?", "ts <= ?");
  const filters = {};
  for (const [k, max] of Object.entries(DIMS)) {
    if (!q.has(k)) continue;
    const v = str(q.get(k), max);
    filters[k] = v === null ? "" : v;
    if (v !== null) binds.push(v);
    switch (k) {
      case "project": where.push(v === null ? "(project IS NULL OR TRIM(project)='')" : "project=?"); break;
      case "stage": where.push(v === null ? "(stage IS NULL OR TRIM(stage)='')" : "stage=?"); break;
      case "runner": where.push(v === null ? "(runner IS NULL OR TRIM(runner)='')" : "runner=?"); break;
      case "model": where.push(v === null ? "(model IS NULL OR TRIM(model)='')" : "model=?"); break;
      case "billing_mode": where.push(v === null ? "(billing_mode IS NULL OR TRIM(billing_mode)='')" : "billing_mode=?"); break;
      case "ticket": where.push(v === null ? "(ticket IS NULL OR TRIM(ticket)='')" : "ticket=?"); break;
    }
  }
  const cols = [];
  for (const d of group) {
    switch (d) {
      case "project": cols.push("NULLIF(TRIM(project),'') AS project"); break;
      case "stage": cols.push("NULLIF(TRIM(stage),'') AS stage"); break;
      case "runner": cols.push("NULLIF(TRIM(runner),'') AS runner"); break;
      case "model": cols.push("NULLIF(TRIM(model),'') AS model"); break;
      case "billing_mode": cols.push("NULLIF(TRIM(billing_mode),'') AS billing_mode"); break;
      case "ticket": cols.push("NULLIF(TRIM(ticket),'') AS ticket"); break;
    }
  }
  return {
    filters,
    rows: {
      sql: `SELECT ts, box, row_hash, project, stage, runner, model, billing_mode, ticket, job_id, run_id, pr, cost_usd, rc, duration_s FROM cost_rows WHERE ${where.join(" AND ")} ORDER BY ts DESC LIMIT ?`,
      binds: [...binds, limit],
    },
    groups: {
      sql: `SELECT ${cols.join(", ")}, ${AGG_COLS.join(", ")}, MAX(ts) AS last_ts${group.includes("ticket") ? LAST_COLS : ""} FROM cost_rows WHERE ${where.join(" AND ")} GROUP BY ${group.length === 2 ? "1, 2" : "1"} ORDER BY SUM(COALESCE(cost_usd,0)) DESC, ${group.length === 2 ? "1, 2" : "1"} LIMIT ?`,
      binds: [...binds, GROUP_CAP],
    },
    total: { sql: `SELECT ${AGG_COLS.join(", ")} FROM cost_rows WHERE ${where.join(" AND ")}`, binds },
  };
}

export const routes = [
  [
    "GET", "/api/metrics/cost-breakdown",
    overloadGuardedRoute("cost_rows", async ({ env, url, t }) => {
      const q = url.searchParams;
      const since = str(q.get("since"), 64) || (t.slice(0, 10) + "T00:00:00Z");
      const until = str(q.get("until"), 64) || t;
      if (!ISO_RE.test(since)) return json(400, { error: "since must be an ISO UTC timestamp" });
      if (!ISO_RE.test(until)) return json(400, { error: "until must be an ISO UTC timestamp" });

      const groupRaw = str(q.get("group"), 64) || "project";
      const rowsMode = groupRaw === "rows";
      const group = rowsMode ? [] : groupRaw.split(",");
      if (!rowsMode) {
        if (group.length > 2) return json(400, { error: "group takes at most 2 dimensions" });
        if (group.some((d) => !Object.hasOwn(DIMS, d))) {
          return json(400, { error: `group must be rows or 1-2 of ${Object.keys(DIMS).join("|")}` });
        }
        if (new Set(group).size !== group.length) return json(400, { error: "group repeats a dimension" });
      }

      let limit = ROWS_DEFAULT;
      if (rowsMode && q.has("limit")) {
        limit = Number(q.get("limit"));
        if (!Number.isInteger(limit) || limit < 1 || limit > ROWS_MAX) {
          return json(400, { error: `limit must be an integer 1..${ROWS_MAX}` });
        }
      }

      const st = statements(q, since, until, group, limit);
      const { filters } = st;

      await ensureColumns(env, "cost_rows");

      // A range older than the hot store reads the archive too (BH-6779); a
      // row in both stores (box, row_hash) appears once.
      if (rowsMode) {
        const h = await readHistory(env, { table: "cost_rows", since, now: t, hot: st.rows });
        const rows = mergeRows(h.hot.results || [], h.archive && (h.archive.results || []), {
          key: (r) => `${r.box}\u0000${r.row_hash}`,
          compare: (a, b) => desc(a.ts, b.ts) || asc(a.box, b.box) || asc(a.row_hash, b.row_hash),
          limit,
        });
        return json(200, { since, until, filters, rows, truncated: rows.length === limit, archive: h.state, as_of: t });
      }

      const [g, tot] = await Promise.all([
        readHistory(env, { table: "cost_rows", since, now: t, hot: st.groups }),
        readHistory(env, { table: "cost_rows", since, now: t, hot: st.total, method: "first" }),
      ]);
      // Each store groups and sums its own rows; the two answers merge here.
      // A row in both stores counts twice in a sum: an aggregate cannot dedupe.
      const merged = mergeGroups(g.hot.results || [], g.archive && (g.archive.results || []), {
        by: group, spec: { ...AGG_SPEC, last_ts: "max" }, pickBy: "last_ts", limit: GROUP_CAP,
        compare: (a, b) => ((b.usd ?? 0) - (a.usd ?? 0)) || group.reduce((c, d) => c || asc(a[d], b[d]), 0),
      });
      const groups = merged.rows;
      // An aggregate with no GROUP BY always returns one row; over zero rows its
      // SUMs are NULL. usd stays null (nothing priced); the others are counts
      // and sums of a measured empty window, so 0 is the true answer.
      const total = mergeAggregate(tot.hot, tot.archive, AGG_SPEC);
      // One store unread makes the whole answer partial.
      const states = [g.state, tot.state];
      const archive = states.includes("unreadable") ? "unreadable" : states.includes("read") ? "read" : g.state;
      return json(200, {
        since, until, group, filters,
        total: {
          usd: total.usd ?? null,
          cash_usd: total.cash_usd ?? 0, equiv_usd: total.equiv_usd ?? 0,
          calls: total.calls ?? 0, unpriced_calls: total.unpriced_calls ?? 0,
        },
        groups, truncated: merged.truncated, archive, as_of: t,
      });
    }),
  ],
];

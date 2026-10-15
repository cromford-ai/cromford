// gh-ledger routes — BH-1574: the fleet GitHub-call ledger.
//
// Every box (the hub, the watcher boxes, each Fly builder) keeps its own
// state/gh-rest-ledger/<hour>.tsv — one line per GitHub request, written by
// gh_rest (bin/lib/gh-rest-ledger.sh) and by the PATH shim bin/gh-ledger/gh.
// bin/gh-ledger-push.sh folds each hour file into aggregates and POSTs them here;
// bin/gh-quota-report.sh GETs a window back and prints the fleet per box, per
// bucket and per caller. See the gh_ledger comment in schema.sql for why the
// table is keyed the way it is.

import { json } from "../lib/http.js";
import { intOrNull, strictInt, str, ensureTable } from "../lib/core.js";

// Wire bounds, not business knobs: one POST is one D1 batch (one transaction),
// and a read answers at most this many grouped rows — the answer says
// `truncated` rather than pretending a capped sum is the whole window.
export const GH_LEDGER_MAX_ROWS = 2000;
export const GH_LEDGER_READ_LIMIT = 5000;
// Each push deletes at most this many expired rows, oldest first, so a long
// backlog drains across pushes instead of in one statement.
export const GH_LEDGER_PRUNE_LIMIT = 5000;
// THE SETTINGS ROW WINS (`gh.ledger.retention_days`, seeded in schema.sql)
// whenever it parses as a positive integer; this is only what an absent or
// unusable row falls back to — never 0, which would delete the present.
export const GH_LEDGER_RETENTION_KEY = "gh.ledger.retention_days";
export const GH_LEDGER_RETENTION_DAYS_DEFAULT = 14;

const HOUR_RE = /^\d{4}-\d{2}-\d{2}T\d{2}$/;

// "YYYY-MM-DDTHH" moved back by whole days. Hours are compared as strings in
// SQL, which is correct only because every one of them has exactly this shape.
function hourMinusDays(hour, days) {
  const ms = Date.parse(`${hour}:00:00Z`) - days * 86400e3;
  return new Date(ms).toISOString().slice(0, 13);
}

async function retentionDays(env) {
  try {
    const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1")
      .bind(GH_LEDGER_RETENTION_KEY).first();
    const n = r ? strictInt(r.value) : null;
    return n !== null && n > 0 ? n : GH_LEDGER_RETENTION_DAYS_DEFAULT;
  } catch {
    return GH_LEDGER_RETENTION_DAYS_DEFAULT;
  }
}

// One pushed aggregate, or null when it cannot be keyed. Text key columns
// default to "-" — the ledger's own spelling of "not recorded" — so a legacy
// line and a new one never collide on a NULL that SQLite would treat as
// distinct from itself in the primary key.
function aggregateRow(r) {
  if (!r || typeof r !== "object") return null;
  const hour = typeof r.hour === "string" && HOUR_RE.test(r.hour) ? r.hour : null;
  const calls = strictInt(r.calls);
  const counted = strictInt(r.counted);
  if (!hour || calls === null || calls < 0 || counted === null || counted < 0) return null;
  return {
    hour,
    lane: str(r.lane, 128) || "-",
    project: str(r.project, 128) || "-",
    meter: str(r.meter, 64) || "-",
    resource: str(r.resource, 32) || "-",
    method: str(r.method, 16) || "-",
    path_class: str(r.path_class, 256) || "-",
    status: str(r.status, 8) || "000",
    source: str(r.source, 16) || "-",
    calls, counted,
    remaining_min: intOrNull(r.remaining_min),
    used_max: intOrNull(r.used_max),
    limit_max: intOrNull(r.limit_max),
    reset_max: intOrNull(r.reset_max),
  };
}

export const routes = [
  [
    "POST", "/api/metrics/gh-ledger",
    async ({ env, t, body }) => {
      const box = str(body.box, 128);
      if (!box) return json(400, { error: "box required" });
      const raw = Array.isArray(body.rows) ? body.rows : [];
      if (!raw.length) return json(400, { error: "rows[] required" });
      if (raw.length > GH_LEDGER_MAX_ROWS) {
        return json(400, { error: `at most ${GH_LEDGER_MAX_ROWS} rows per request` });
      }
      const rows = [];
      for (let i = 0; i < raw.length; i++) {
        const r = aggregateRow(raw[i]);
        // The WHOLE request is refused: a box that sent one unkeyable row has
        // a bug, and silently landing the rest would make its hour look
        // smaller than it was with nothing to say so.
        if (!r) return json(400, { error: `row ${i}: hour (YYYY-MM-DDTHH), calls and counted (non-negative integers) are required` });
        rows.push(r);
      }
      await ensureTable(env, "gh_ledger");
      const stmts = rows.map((r) => env.DB.prepare(
        `INSERT INTO gh_ledger (box, hour, lane, project, meter, resource, method, path_class,
                                status, source, calls, counted, remaining_min, used_max,
                                limit_max, reset_max, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)
         ON CONFLICT(box, hour, lane, project, meter, resource, method, path_class, status, source)
         DO UPDATE SET calls=excluded.calls, counted=excluded.counted,
           remaining_min=excluded.remaining_min, used_max=excluded.used_max,
           limit_max=excluded.limit_max, reset_max=excluded.reset_max,
           updated_at=excluded.updated_at`
      ).bind(box, r.hour, r.lane, r.project, r.meter, r.resource, r.method, r.path_class,
             r.status, r.source, r.calls, r.counted, r.remaining_min, r.used_max,
             r.limit_max, r.reset_max, t));
      const results = await env.DB.batch(stmts);
      const changed = (Array.isArray(results) ? results : [])
        .reduce((a, x) => a + ((x && x.meta && Number(x.meta.changes)) || 0), 0);

      // RETENTION, measured from the NEWEST hour this push carried — capped at
      // the server's own hour, so a box whose clock runs ahead can never make
      // the fleet's history look expired. Never from the wall clock alone: a
      // replayed backlog and a test both get the same answer on any day.
      const days = await retentionDays(env);
      let ref = rows.reduce((a, r) => (r.hour > a ? r.hour : a), rows[0].hour);
      const now = t.slice(0, 13);
      if (ref > now) ref = now;
      const before = hourMinusDays(ref, days);
      const pr = await env.DB.prepare(
        `DELETE FROM gh_ledger WHERE rowid IN (
           SELECT rowid FROM gh_ledger WHERE hour < ?1 ORDER BY hour ASC LIMIT ?2)`
      ).bind(before, GH_LEDGER_PRUNE_LIMIT).run();
      const pruned = (pr && pr.meta && Number(pr.meta.changes)) || 0;
      return json(200, { accepted: rows.length, changed, pruned, retention_days: days, as_of: t });
    },
  ],

  // The read side, GROUPED so a day of the whole fleet is a few thousand rows
  // rather than every (hour, method, status, project) cell: per box, caller,
  // meter, bucket and path class, which is every grouping the report prints.
  // `since` is REQUIRED — an unbounded scan of the table is refused, not run.
  [
    "GET", "/api/metrics/gh-ledger",
    async ({ env, url, t }) => {
      const since = url.searchParams.get("since") || "";
      const until = url.searchParams.get("until") || "";
      if (!HOUR_RE.test(since)) return json(400, { error: "since=YYYY-MM-DDTHH is required" });
      if (until && !HOUR_RE.test(until)) return json(400, { error: "until must be YYYY-MM-DDTHH" });
      await ensureTable(env, "gh_ledger");
      const where = ["hour >= ?1"];
      const binds = [since];
      if (until) { binds.push(until); where.push(`hour <= ?${binds.length}`); }
      const box = str(url.searchParams.get("box"), 128);
      if (box) { binds.push(box); where.push(`box = ?${binds.length}`); }
      binds.push(GH_LEDGER_READ_LIMIT + 1);
      // sql-ident-ok: where holds literal column = ?N clauses, every value a bind
      const res = await env.DB.prepare(
        `SELECT box, lane, meter, resource, path_class,
                SUM(calls) AS calls, SUM(counted) AS counted,
                MIN(remaining_min) AS remaining_min, MAX(used_max) AS used_max,
                MAX(limit_max) AS limit_max, MAX(reset_max) AS reset_max
           FROM gh_ledger WHERE ${where.join(" AND ")}
          GROUP BY box, lane, meter, resource, path_class
          ORDER BY counted DESC, box, lane, meter, resource, path_class
          LIMIT ?${binds.length}`
      ).bind(...binds).all();
      const rows = res.results || [];
      const truncated = rows.length > GH_LEDGER_READ_LIMIT;
      return json(200, {
        rows: truncated ? rows.slice(0, GH_LEDGER_READ_LIMIT) : rows,
        truncated, since, until: until || null, as_of: t,
      });
    },
  ],
];

// cost-live routes — spend that is still running (BH-3481.2 / BH-3499).
//
// cost_rows only learns what a claude session cost when the session ends and
// its final row is pushed. A long build spends for an hour before that, and
// nothing could see it. A running session's meter now POSTs its running total
// here, one row per session, and GET answers what is in flight right now.
//
// Row shape (the meter matches it):
//   row_hash    sha256("live|<box>|<session_id>"), 64 hex chars
//   session_id  the claude --session-id; the same id its final cost_rows row carries
//   run_id      the build dir basename
//   the rest    named like the cost_rows_live columns in schema.sql
//   updated_at  ignored if sent: the worker stamps its own clock, so staleness
//               is judged on the clock that wrote it
//
// A live row is SETTLED once a cost_rows row with the same session_id exists.
// Settled rows are counted in settled_sessions and never in either dollar
// figure, because the final row now carries that money.

import { json } from "../lib/http.js";
import { str, numOrNull, intOrNull } from "../lib/core.js";

// Protocol bounds, not business thresholds. The meter chunks to MAX_ROWS.
const MAX_ROWS = 50;
const PRUNE_DAYS = 14;
const PRUNE_BATCH = 500;
const GET_LIMIT = 500;
const HOURS_DEFAULT = 24, HOURS_MIN = 1, HOURS_MAX = 336;
const STALE_DEFAULT = 900, STALE_MIN = 60, STALE_MAX = 86400;

// Same format as nowIso(): no millis. A cutoff with millis would compare
// against stored stamps one byte off (`.` sorts before `Z`).
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const round4 = (n) => Math.round(n * 1e4) / 1e4;
function param(v, dflt, min, max) {
  const n = v === null || v === "" ? NaN : Number(v);
  return Number.isFinite(n) ? Math.min(Math.max(n, min), max) : dflt;
}

const SETTLED = "EXISTS (SELECT 1 FROM cost_rows c WHERE c.session_id = l.session_id)";

export const routes = [
  [
    "POST", "/api/cost/live",
    async ({ env, t, body }) => {
      const box = str(body.box, 128);
      if (!box) return json(400, { error: "box required" });
      if (!Array.isArray(body.rows) || body.rows.length === 0) return json(400, { error: "rows[] required" });
      if (body.rows.length > MAX_ROWS) return json(400, { error: `at most ${MAX_ROWS} rows per request` });

      const valid = [];
      for (const r of body.rows) {
        if (!r || typeof r !== "object") continue;
        const row_hash = str(r.row_hash, 64), session_id = str(r.session_id, 64);
        if (!row_hash || !session_id) continue;
        valid.push({
          row_hash, session_id, run_id: str(r.run_id, 128), ticket: str(r.ticket, 128),
          project: str(r.project, 128), stage: str(r.stage, 64), model: str(r.model, 128),
          input_toks: intOrNull(r.input_toks), output_toks: intOrNull(r.output_toks),
          cache_read: intOrNull(r.cache_read), cache_write: intOrNull(r.cache_write),
          cost_usd: numOrNull(r.cost_usd), unpriced: str(r.unpriced, 256), started_at: str(r.started_at, 64),
        });
      }
      if (valid.length === 0) return json(400, { error: "no row carried row_hash and session_id" });
      // A test run's meter posts testproj rows. Dropping them is not an error.
      // A duplicate row_hash in one request: the last one wins, counted once.
      const byHash = new Map();
      for (const r of valid) if (r.project !== "testproj") byHash.set(r.row_hash, r);
      const rows = [...byHash.values()];
      if (rows.length === 0) return json(200, { inserted: 0, updated: 0, unchanged: 0, as_of: t });

      // Which rows exist already tells an insert from an update; the batch's
      // own change counts tell a write from a refused one.
      const marks = rows.map((_, i) => `?${i + 2}`).join(",");
      // sql-ident-ok: marks is a ?N placeholder list built from the rows index
      const have = await env.DB.prepare(
        `SELECT row_hash FROM cost_rows_live WHERE box=?1 AND row_hash IN (${marks})`
      ).bind(box, ...rows.map((r) => r.row_hash)).all();
      const existing = new Set((have.results || []).map((r) => r.row_hash));

      // Monotonic: a lower cost never lowers the row (an out-of-order push), a
      // NULL cost never overwrites a number, and an unpriced row can become
      // priced. An identical re-push changes nothing, updated_at included.
      const stmts = rows.map((r) => env.DB.prepare(
        `INSERT INTO cost_rows_live (box,row_hash,session_id,run_id,ticket,project,stage,model,
           input_toks,output_toks,cache_read,cache_write,cost_usd,unpriced,started_at,updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)
         ON CONFLICT(box,row_hash) DO UPDATE SET
           session_id=excluded.session_id, run_id=excluded.run_id, ticket=excluded.ticket,
           project=excluded.project, stage=excluded.stage, model=excluded.model,
           input_toks=excluded.input_toks, output_toks=excluded.output_toks,
           cache_read=excluded.cache_read, cache_write=excluded.cache_write,
           cost_usd=excluded.cost_usd, unpriced=excluded.unpriced,
           started_at=COALESCE(cost_rows_live.started_at, excluded.started_at),
           updated_at=excluded.updated_at
         WHERE (cost_rows_live.cost_usd IS NULL OR excluded.cost_usd >= cost_rows_live.cost_usd)
           AND NOT (excluded.cost_usd IS cost_rows_live.cost_usd
                    AND excluded.input_toks IS cost_rows_live.input_toks
                    AND excluded.output_toks IS cost_rows_live.output_toks
                    AND excluded.cache_read IS cost_rows_live.cache_read
                    AND excluded.cache_write IS cost_rows_live.cache_write
                    AND excluded.unpriced IS cost_rows_live.unpriced)`
      ).bind(box, r.row_hash, r.session_id, r.run_id, r.ticket, r.project, r.stage, r.model,
             r.input_toks, r.output_toks, r.cache_read, r.cache_write, r.cost_usd, r.unpriced,
             r.started_at, t));
      const out = await env.DB.batch(stmts);
      let inserted = 0, updated = 0, unchanged = 0;
      rows.forEach((r, i) => {
        const changed = Number(out[i]?.meta?.changes || 0) > 0;
        if (!changed) unchanged++;
        else if (existing.has(r.row_hash)) updated++;
        else inserted++;
      });

      // Bounded prune. D1 has no DELETE … LIMIT (see call-guard.js), so the
      // bound rides in a rowid subquery. The ingest already succeeded, so a
      // failed prune is left for the next POST.
      try {
        // sql-ident-ok: PRUNE_BATCH is a module number const
        await env.DB.prepare(
          `DELETE FROM cost_rows_live WHERE rowid IN
             (SELECT rowid FROM cost_rows_live WHERE updated_at < ?1 LIMIT ${PRUNE_BATCH})`
        ).bind(iso(Date.parse(t) - PRUNE_DAYS * 86400e3)).run();
      } catch { /* next POST prunes */ }

      return json(200, { inserted, updated, unchanged, as_of: t });
    },
  ],

  [
    "GET", "/api/cost/live",
    async ({ env, url, t }) => {
      const now = Date.parse(t);
      const hours = param(url.searchParams.get("hours"), HOURS_DEFAULT, HOURS_MIN, HOURS_MAX);
      const staleS = param(url.searchParams.get("stale_s"), STALE_DEFAULT, STALE_MIN, STALE_MAX);
      const where = ["l.updated_at >= ?"], binds = [iso(now - hours * 3600e3)];
      for (const k of ["run_id", "project"]) {
        const v = str(url.searchParams.get(k), 128);
        if (v) { where.push(`l.${k} = ?`); binds.push(v); }
      }
      const fresh = iso(now - staleS * 1000);
      const W = where.join(" AND ");

      // The sums come from every matching row, never from the capped page
      // below: a sum over a truncated page is silently short.
      // sql-ident-ok: W uses column names from a literal list, values bound; SETTLED is a module const clause
      const agg = await env.DB.prepare(
        `SELECT
           SUM(CASE WHEN s=0 AND fresh=1 AND cost_usd IS NOT NULL THEN cost_usd END) AS in_flight_sum,
           SUM(CASE WHEN s=0 AND fresh=1 AND cost_usd IS NOT NULL THEN 1 ELSE 0 END) AS in_flight_priced,
           SUM(CASE WHEN s=0 AND fresh=1 THEN 1 ELSE 0 END) AS in_flight_rows,
           SUM(CASE WHEN s=0 AND fresh=0 THEN COALESCE(cost_usd,0) ELSE 0 END) AS unsettled_usd,
           COUNT(DISTINCT CASE WHEN s=1 THEN session_id END) AS settled_sessions,
           SUM(CASE WHEN s=0 AND (cost_usd IS NULL OR COALESCE(unpriced,'')<>'') THEN 1 ELSE 0 END) AS unpriced_rows
         FROM (SELECT l.session_id, l.cost_usd, l.unpriced, ${SETTLED} AS s, (l.updated_at >= ?) AS fresh
               FROM cost_rows_live l WHERE ${W})`
      ).bind(fresh, ...binds).first();
      const flightRows = Number(agg?.in_flight_rows || 0);
      // Nothing running is an honest 0. Something running with no price is
      // unknown, and unknown is null, never 0.
      const in_flight_usd = flightRows === 0 ? 0
        : Number(agg.in_flight_priced || 0) === 0 ? null
        : round4(Number(agg.in_flight_sum));

      // sql-ident-ok: SETTLED is a module const clause; W uses literal column names; GET_LIMIT is a module number const
      const page = await env.DB.prepare(
        `SELECT l.*, ${SETTLED} AS settled_, (l.updated_at >= ?) AS fresh_
         FROM cost_rows_live l WHERE ${W} ORDER BY l.updated_at DESC LIMIT ${GET_LIMIT + 1}`
      ).bind(fresh, ...binds).all();
      const got = page.results || [];
      const truncated = got.length > GET_LIMIT;
      const rows = got.slice(0, GET_LIMIT).map(({ settled_, fresh_, ...r }) => ({
        ...r, state: settled_ ? "settled" : fresh_ ? "in_flight" : "unsettled",
      }));

      return json(200, {
        rows, in_flight_usd, unsettled_usd: round4(Number(agg?.unsettled_usd || 0)),
        settled_sessions: Number(agg?.settled_sessions || 0),
        unpriced_rows: Number(agg?.unpriced_rows || 0), truncated, as_of: t,
      });
    },
  ],
];

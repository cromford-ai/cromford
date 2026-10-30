// retention routes — scheduled D1 retention (BH-6750, slice 2 of BH-6727).
//
// POST /api/retention/run {dry_run?: true}
//   The hub lane bin/d1-retention.sh calls it every hour. For each rule below
//   it reads the eligible ids oldest first (an index range, LIMIT batch),
//   deletes them by id in ONE statement, and repeats until the rule has
//   removed retention.max_rows or nothing is left. It then writes ONE
//   retention_runs row per rule. retention.dry_run=1 (the seed) or a body
//   {dry_run:true} counts the eligible rows (capped at retention.count_cap)
//   and deletes nothing. A body can ask for a dry run; it can never force a
//   real one.
//
// WHY BOUNDED. The database answered "overloaded" on 2026-10-14 (BH-6727). A
//   run removes at most max_rows per rule in statements of `batch` rows, so a
//   large backlog drains over several hourly runs instead of in one burst.
//
// NEVER DELETED HERE: ledgers (claim keys as well as history: an archived row
//   would read as "not done"; BH-6774 C2 moves kinds one by one). cost_rows are
//   never deleted either: the cost_rows.archive rule MOVES them to the archive
//   store (BH-6774), off by default (retention.cost_rows.archive_days = 0).
//   stage_events_daily rows leave hot only with a verified copy in the archive
//   D1 (BH-7109, lib/archive-daily.js), and that rule is off by default.
//
// COPY BEFORE DELETE (BH-6774). A rule with `archive` copies each batch to
//   the archive D1 (src/lib/archive.js), counts it back, and only then runs the
//   delete. A failed or short copy deletes nothing and records the error. With
//   the archive binding absent, such a rule deletes nothing and its audit row says
//   "archive not bound" (a dry run still counts). stage_events archive only
//   when retention.stage_events.archive=1; with it 0 they are rolled up and
//   deleted as in BH-6750.
//
// ARCHIVED, NOT LOST: fly_idle_stops and fly_idle_destroys (BH-6877), the Fly
//   idle reaper's cost audit. Their rules add each removed row to
//   fly_idle_daily (day, app, action, n, $/h sum) in the same D1 batch,
//   before the delete. fly_idle_daily has no rule: it keeps forever.
//   roadmap_ideas (discarded), roadmap_idea_events and roadmap_waves (rejected
//   or failed) copy to the archive D1 before the delete (BH-7243.0). With the
//   archive unbound they report "archive not bound" only while a row waits.
//
// Every setting is a settings row (worker/jobs/schema.d/*-bh-6750-*.sql). A
// value that is not an integer in range falls back to the code default below;
// a window of 0 turns that rule off.
import { d1Guarded, json } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { ARCHIVE_NOT_BOUND, archiveDailyBound } from "../lib/archive-daily.js";
import { archiveBound, archiveCopy, ensureArchiveTable } from "../lib/archive.js";
import { RULES as FRAGMENT_RULES } from "#retention-rules";

const DAY_MS = 86400e3;
export { COST_ARCHIVE_FLOOR_DAYS } from "./retention.d/bh-6774-cost-rows.js";

// rule: the id read takes (?1 cutoff, ?2 limit) and returns `id`; the delete
// takes (?1 a JSON array of ids). `rollup` (optional) takes the same JSON ids
// and runs in the same D1 batch as the delete, before it. `pre` (optional) is
// a list of child deletes that take the same JSON ids and run in that batch
// before the delete, so a parent never goes without its children. `move`
// (optional, BH-7109) takes (env, JSON ids, now) and returns the rows the
// archive verified as [{id, n}]; the delete then takes that JSON list instead
// of the ids, and deletes a row only while its hot n still matches.
//
// WHERE A RULE LIVES (BH-8398.0, BH-8398.1). A new rule is a new file
// retention.d/bh-<n>-<name>.js that does `export default [ ...rules ]`.
// RULES is the composed retention.d/ list; retention.js holds no rule. A
// fragment imports only from ../../lib/, never from this file. Node reads the
// fragments through src/lib/retention-rules.node.js and wrangler bundles the
// render src/retention-rules.gen.js; both run checkRules and compose in
// fragment-name order (the numeric ticket, then the name).
export const RULES = FRAGMENT_RULES;

// intSetting(byKey, key, def, min, max) — the row's value when it is an integer
// in [min, max], else def. routes/roadmap-ideas.js reads its list cap with it.
export function intSetting(byKey, key, def, min, max) {
  const row = byKey.get(key);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return def;
  const n = Number(v);
  return n >= min && n <= max ? n : def;
}
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

async function runRule(env, r, o) {
  const started = iso(Date.now());
  const out = { rule: r.rule, table: r.table, cutoff: null, counted: 0, removed: 0, rolled_up: 0, backlog: false, off: false, error: null };
  const set = intSetting(o.byKey, r.key, r.def, 0, 3650);
  if (set === 0) { out.off = true; return { out, started }; }
  // floorDays: a window below it is raised to it, so no hot-only reader loses
  // rows inside its own window (BH-6774).
  const days = Math.max(set, r.floorDays || 0);
  out.cutoff = iso(o.nowMs - days * DAY_MS);
  const archiving = !!r.archive && (!r.archiveFlag || intSetting(o.byKey, r.archiveFlag, 0, 0, 1) === 1);
  // An unbound archive rule moves nothing. A dry run still counts, so the
  // operator sees the estimate before the binding exists (BH-6774).
  if (archiving && !archiveBound(env) && !r.quietUnbound) {
    out.error = ARCHIVE_NOT_BOUND;
    if (!o.dryRun) return { out, started };
  }
  if (r.move && !archiveDailyBound(env)) { out.error = ARCHIVE_NOT_BOUND; return { out, started }; }
  try {
    // quietUnbound (BH-7243.0): with the archive unbound, the rule moves
    // nothing and counts what waits. "archive not bound" is an error only
    // while a row waits: the rule is on by default, and the lane raises an
    // alert for each rule error, so empty tables must not raise one each run.
    if (archiving && !archiveBound(env) && r.quietUnbound) {
      // sql-ident-ok: r.ids is literal subquery text from the RULES module const
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM (${r.ids})`).bind(out.cutoff, o.countCap + 1).first();
      const n = Number(row ? row.n : 0);
      if (n > 0) out.error = ARCHIVE_NOT_BOUND;
      if (o.dryRun) out.counted = Math.min(n, o.countCap);
      out.backlog = n > 0;
      return { out, started };
    }
    if (o.dryRun) {
      // sql-ident-ok: r.ids is literal subquery text from the RULES module const
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM (${r.ids})`).bind(out.cutoff, o.countCap + 1).first();
      const n = Number(row ? row.n : 0);
      out.counted = Math.min(n, o.countCap);
      out.backlog = n > 0;
      return { out, started };
    }
    let tableReady = false;
    while (out.removed < o.maxRows) {
      const want = Math.min(o.batch, o.maxRows - out.removed);
      const ids = ((await env.DB.prepare(r.ids).bind(out.cutoff, want).all()).results || []).map((x) => x.id);
      if (ids.length === 0) break;
      let arr = JSON.stringify(ids);
      let ok = null;
      if (archiving) {
        // Once per run, on the first batch: two PRAGMA reads, not two per batch.
        if (!tableReady) { await ensureArchiveTable(env, r.archive); tableReady = true; }
        const rows = (await env.DB.prepare(r.sel).bind(arr).all()).results || [];
        if (!(await archiveCopy(env, r.archive, rows, iso(Date.now())))) {
          out.error = `archive copy not verified (${rows.length} rows); nothing deleted`;
          break;
        }
      }
      if (r.move) {
        // A throw (a failed copy) goes to the catch below: nothing is deleted.
        ok = await r.move(env, arr, iso(Date.now()));
        arr = JSON.stringify(ok);
      }
      const stmts = [];
      if (r.rollup) stmts.push(env.DB.prepare(r.rollup).bind(arr));
      for (const sql of r.pre || []) stmts.push(env.DB.prepare(sql).bind(arr));
      stmts.push(env.DB.prepare(r.del).bind(arr));
      const res = ok && ok.length === 0 ? null : await env.DB.batch(stmts);
      if (ok) {
        // A row the archive does not hold with the same n, or whose hot n grew
        // after the copy, is not deleted; the rule stops for this run.
        const gone = res ? Number(res[res.length - 1].meta.changes) : 0;
        out.removed += gone;
        if (gone < ids.length) {
          out.error = `archive copy not verified for ${ids.length - gone} of ${ids.length} rows; those rows stay`;
          break;
        }
      } else {
        out.removed += ids.length;
      }
      if (r.rollup) out.rolled_up += ids.length;
      if (ids.length < want) break;
    }
    out.counted = out.removed;
    const more = (await env.DB.prepare(r.ids).bind(out.cutoff, 1).all()).results || [];
    out.backlog = more.length > 0;
  } catch (e) {
    out.error = String((e && e.message) || e).slice(0, 300);
  }
  return { out, started };
}

export const routes = [
  [
    "POST", "/api/retention/run",
    ({ env, t, body }) => d1Guarded("retention_runs", async () => {
      const { byKey } = await settingsRows(env);
      const nowMs = Date.parse(t);
      const o = {
        byKey, nowMs,
        dryRun: (body && body.dry_run === true) || intSetting(byKey, "retention.dry_run", 1, 0, 1) === 1,
        batch: intSetting(byKey, "retention.batch", 500, 1, 2000),
        maxRows: intSetting(byKey, "retention.max_rows", 5000, 1, 100000),
        countCap: intSetting(byKey, "retention.count_cap", 250000, 1, 1000000),
      };
      const runId = `ret-${t}`;
      const results = [];
      for (const r of RULES) {
        const { out, started } = await runRule(env, r, o);
        results.push(out);
        if (out.off) continue;
        await env.DB.prepare(
          `INSERT INTO retention_runs (run_id, rule, tbl, dry_run, cutoff, counted, removed, rolled_up, backlog, error, started_at, finished_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)`
        ).bind(runId, out.rule, out.table, o.dryRun ? 1 : 0, out.cutoff, out.counted, out.removed, out.rolled_up,
          out.backlog ? 1 : 0, out.error, started, iso(Date.now())).run();
      }
      return json(200, {
        run_id: runId, dry_run: o.dryRun, batch: o.batch, max_rows: o.maxRows, rules: results, as_of: t,
      });
    }),
  ],
];

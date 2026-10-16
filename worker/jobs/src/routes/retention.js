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
// NEVER DELETED HERE: cost_rows and ledgers (money and history). There is no
//   rule for them. Archiving them is a later slice.
//
// Every setting is a settings row (worker/jobs/schema.d/*-bh-6750-*.sql). A
// value that is not an integer in range falls back to the code default below;
// a window of 0 turns that rule off.
import { d1Guarded, json } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

const DAY_MS = 86400e3;

// rule: the id read takes (?1 cutoff, ?2 limit) and returns `id`; the delete
// takes (?1 a JSON array of ids). `rollup` (optional) takes the same JSON ids
// and runs in the same D1 batch as the delete, before it. `pre` (optional) is
// a list of child deletes that take the same JSON ids and run in that batch
// before the delete, so a parent never goes without its children.
export const RULES = [
  {
    rule: "wakes.age", table: "wakes", key: "retention.wakes.days", def: 30,
    ids: "SELECT id FROM wakes WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM wakes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "wakes.acked", table: "wakes", key: "retention.wakes.acked_days", def: 3,
    ids: "SELECT id FROM wakes WHERE acked_at IS NOT NULL AND acked_at < ?1 ORDER BY acked_at LIMIT ?2",
    del: "DELETE FROM wakes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-6744: a landing shadow decision is a diagnostic with no reader after
  // wave 5's replay window; not money or history, so it is deleted.
  {
    rule: "landing_decisions.age", table: "landing_decisions", key: "retention.landing_decisions.days", def: 90,
    ids: "SELECT id FROM landing_decisions WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM landing_decisions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "job_heartbeats.closed", table: "job_heartbeats", key: "retention.job_heartbeats.days", def: 30,
    ids: `SELECT h.job_id AS id FROM job_heartbeats h LEFT JOIN jobs j ON j.id = h.job_id
           WHERE h.beat_at < ?1 AND (j.id IS NULL OR j.status <> 'running')
           ORDER BY h.beat_at LIMIT ?2`,
    del: "DELETE FROM job_heartbeats WHERE job_id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "stage_events.closed", table: "stage_events", key: "retention.stage_events.days", def: 90,
    ids: `SELECT e.id AS id FROM stage_events e LEFT JOIN jobs j ON j.id = e.job_id
           WHERE e.created_at < ?1 AND (j.id IS NULL OR j.status <> 'running')
           ORDER BY e.created_at LIMIT ?2`,
    rollup: `INSERT INTO stage_events_daily (day, stage, verdict, actor, n)
             SELECT substr(created_at, 1, 10), stage, COALESCE(verdict, ''), actor, COUNT(*)
               FROM stage_events WHERE id IN (SELECT value FROM json_each(?1))
              GROUP BY 1, 2, 3, 4
             ON CONFLICT (day, stage, verdict, actor) DO UPDATE SET n = n + excluded.n`,
    del: "DELETE FROM stage_events WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "lane_ticks.stale", table: "lane_ticks", key: "retention.lane_ticks.days", def: 30,
    ids: "SELECT rowid AS id FROM lane_ticks WHERE last_tick_at < ?1 ORDER BY last_tick_at LIMIT ?2",
    del: "DELETE FROM lane_ticks WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // BH-6889: a machine's alert line, once the hub replayed it into ALERTS.log
  // (applied_at set), and a line the hub never replayed (the publisher off).
  {
    rule: "alert_lines.applied", table: "alert_lines", key: "retention.alert_lines.applied_days", def: 7,
    ids: "SELECT id FROM alert_lines WHERE applied_at < ?1 ORDER BY applied_at LIMIT ?2",
    del: "DELETE FROM alert_lines WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "alert_lines.unapplied", table: "alert_lines", key: "retention.alert_lines.unapplied_days", def: 30,
    ids: "SELECT id FROM alert_lines WHERE applied_at IS NULL AND created_at < ?1 ORDER BY id LIMIT ?2",
    del: "DELETE FROM alert_lines WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "retention_runs.age", table: "retention_runs", key: "retention.retention_runs.days", def: 90,
    ids: "SELECT id FROM retention_runs WHERE started_at < ?1 ORDER BY started_at LIMIT ?2",
    del: "DELETE FROM retention_runs WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-5563: staff learning-loop history. An outcome goes only when it is past
  // the window, applied, and older than its agent's last change
  // (staff_agents.updated_at): the promotion read in staff-outcomes.js reads
  // the rows since that time, so it never loses one. resolved_at is the server
  // time of the insert, so per family the removed rows are always the oldest
  // ids, and the noise count after the newest kept marker does not change.
  {
    rule: "staff_outcomes.age", table: "staff_outcomes", key: "retention.staff_outcomes.days", def: 180,
    ids: `SELECT o.id AS id FROM staff_outcomes o LEFT JOIN staff_agents a ON a.name = o.agent
           WHERE o.resolved_at < ?1 AND o.applied = 1 AND (a.name IS NULL OR o.resolved_at < a.updated_at)
           ORDER BY o.resolved_at LIMIT ?2`,
    del: "DELETE FROM staff_outcomes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // A pending promotion is never removed; a decided one is kept for its window.
  {
    rule: "staff_promotions.void", table: "staff_promotions", key: "retention.staff_promotions.void_days", def: 30,
    ids: "SELECT id FROM staff_promotions WHERE status = 'void' AND decided_at < ?1 ORDER BY decided_at LIMIT ?2",
    del: "DELETE FROM staff_promotions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "staff_promotions.applied", table: "staff_promotions", key: "retention.staff_promotions.applied_days", def: 180,
    ids: "SELECT id FROM staff_promotions WHERE status = 'applied' AND decided_at < ?1 ORDER BY decided_at LIMIT ?2",
    del: "DELETE FROM staff_promotions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // A finished finding is the claim dedup for its fingerprint, so it stays a
  // year; a claimed or filed one is live work and never goes. The IN list is
  // the partial index's own WHERE, so the read uses idx_staff_findings_done.
  // Its children go first, in the same batch: the outcome row and the
  // 'staff:<fp>' decision row. Left behind, a re-filed finding would meet the
  // old outcome (409 ticket_mismatch every hour) and the old decision (INSERT
  // OR IGNORE keeps it, so the new choice is never counted).
  {
    rule: "staff_findings.done", table: "staff_findings", key: "retention.staff_findings.done_days", def: 365,
    ids: `SELECT id FROM staff_findings
           WHERE status IN ('digested','refused','unsupported','failed','merged','rejected','noise') AND updated_at < ?1
           ORDER BY updated_at LIMIT ?2`,
    pre: [
      `DELETE FROM staff_outcomes WHERE fingerprint IN
         (SELECT fingerprint FROM staff_findings WHERE id IN (SELECT value FROM json_each(?1)))`,
      `DELETE FROM staff_decisions WHERE escalation_key IN
         (SELECT 'staff:' || fingerprint FROM staff_findings WHERE id IN (SELECT value FROM json_each(?1)))`,
    ],
    del: "DELETE FROM staff_findings WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // Revoked and expired suppressions mute nothing; a pending one never goes.
  {
    rule: "staff_suppressions.revoked", table: "staff_suppressions", key: "retention.staff_suppressions.revoked_days", def: 180,
    ids: "SELECT id FROM staff_suppressions WHERE status = 'revoked' AND created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM staff_suppressions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "staff_suppressions.expired", table: "staff_suppressions", key: "retention.staff_suppressions.expired_days", def: 180,
    ids: "SELECT id FROM staff_suppressions WHERE status = 'active' AND expires_at < ?1 ORDER BY expires_at LIMIT ?2",
    del: "DELETE FROM staff_suppressions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-6977: an edge's `at` moves on every write; a hold's `at` is its comment's time.
  {
    rule: "ticket_edges.age", table: "ticket_edges", key: "retention.ticket_edges.days", def: 365,
    ids: "SELECT id FROM ticket_edges WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM ticket_edges WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "ticket_holds.age", table: "ticket_holds", key: "retention.ticket_holds.days", def: 365,
    ids: "SELECT id FROM ticket_holds WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM ticket_holds WHERE id IN (SELECT value FROM json_each(?1))",
  },
];

// intSetting(byKey, key, def, min, max) — the row's value when it is an integer
// in [min, max], else def.
function intSetting(byKey, key, def, min, max) {
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
  const days = intSetting(o.byKey, r.key, r.def, 0, 3650);
  if (days === 0) { out.off = true; return { out, started }; }
  out.cutoff = iso(o.nowMs - days * DAY_MS);
  try {
    if (o.dryRun) {
      // sql-ident-ok: r.ids is literal subquery text from the RULES module const
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM (${r.ids})`).bind(out.cutoff, o.countCap + 1).first();
      const n = Number(row ? row.n : 0);
      out.counted = Math.min(n, o.countCap);
      out.backlog = n > 0;
      return { out, started };
    }
    while (out.removed < o.maxRows) {
      const want = Math.min(o.batch, o.maxRows - out.removed);
      const ids = ((await env.DB.prepare(r.ids).bind(out.cutoff, want).all()).results || []).map((x) => x.id);
      if (ids.length === 0) break;
      const arr = JSON.stringify(ids);
      const stmts = [];
      if (r.rollup) stmts.push(env.DB.prepare(r.rollup).bind(arr));
      for (const sql of r.pre || []) stmts.push(env.DB.prepare(sql).bind(arr));
      stmts.push(env.DB.prepare(r.del).bind(arr));
      await env.DB.batch(stmts);
      out.removed += ids.length;
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

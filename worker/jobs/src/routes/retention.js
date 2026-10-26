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
import { ARCHIVE_NOT_BOUND, archiveDailyBound, moveDailyBatch } from "../lib/archive-daily.js";
import { archiveBound, archiveCopy, ensureArchiveTable } from "../lib/archive.js";

const DAY_MS = 86400e3;
export const COST_ARCHIVE_FLOOR_DAYS = 60;

// rule: the id read takes (?1 cutoff, ?2 limit) and returns `id`; the delete
// takes (?1 a JSON array of ids). `rollup` (optional) takes the same JSON ids
// and runs in the same D1 batch as the delete, before it. `pre` (optional) is
// a list of child deletes that take the same JSON ids and run in that batch
// before the delete, so a parent never goes without its children. `move`
// (optional, BH-7109) takes (env, JSON ids, now) and returns the rows the
// archive verified as [{id, n}]; the delete then takes that JSON list instead
// of the ids, and deletes a row only while its hot n still matches.
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
  // BH-6887: a daily budget counter has no reader after its day; not money or history.
  {
    rule: "mc_budget.age", table: "mc_budget", key: "retention.mc_budget.days", def: 30,
    ids: "SELECT rowid AS id FROM mc_budget WHERE day < substr(?1,1,10) ORDER BY day LIMIT ?2",
    del: "DELETE FROM mc_budget WHERE rowid IN (SELECT value FROM json_each(?1))",
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
    archive: "stage_events", archiveFlag: "retention.stage_events.archive",
    sel: "SELECT * FROM stage_events WHERE id IN (SELECT value FROM json_each(?1))",
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
  // BH-7109: a daily rollup row moves to the archive D1 when its whole day is
  // older than the cutoff date (substr keeps the PK index on `day`) AND older
  // than the oldest event still in stage_events. Off by default (def 0);
  // nothing is deleted while the archive binding is absent.
  // WHY THE EVENT GATE. Every stage_events insert stamps created_at with the
  // server time, so a day older than the oldest hot event can never get
  // another rollup. A day that still has events (a running job, or a backlog
  // that drains over runs) is not moved: a later rollup for an archived day
  // would make a new hot row whose n can equal the archived n, and the
  // count-back would then delete it as "already copied". MIN(created_at) is
  // one uncorrelated read on idx_events_created.
  {
    rule: "stage_events_daily.archive", table: "stage_events_daily", key: "retention.stage_events_daily.archive_days", def: 0,
    ids: `SELECT rowid AS id FROM stage_events_daily
           WHERE day < MIN(substr(?1, 1, 10), COALESCE((SELECT substr(MIN(created_at), 1, 10) FROM stage_events), '9999-12-31'))
           ORDER BY day LIMIT ?2`,
    move: moveDailyBatch,
    del: `DELETE FROM stage_events_daily WHERE rowid IN
           (SELECT d.rowid FROM json_each(?1) j JOIN stage_events_daily d
             ON d.rowid = json_extract(j.value, '$.id') AND d.n = json_extract(j.value, '$.n'))`,
  },
  // BH-7164: an hourly cost bucket is a cache of cost_rows, which keeps every
  // row, so a removed bucket loses nothing. GET /api/progress/stamps reads at
  // most 30 days of buckets; the window must stay above that.
  {
    rule: "cost_project_hourly.age", table: "cost_project_hourly", key: "retention.cost_project_hourly.days", def: 400,
    ids: "SELECT rowid AS id FROM cost_project_hourly WHERE hour < substr(?1, 1, 13) ORDER BY hour LIMIT ?2",
    del: "DELETE FROM cost_project_hourly WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  {
    // BH-6774: cost rows older than the window MOVE to the archive store. The
    // id is the rowid (the key is (box, row_hash)); the read is the ts index.
    rule: "cost_rows.archive", table: "cost_rows", key: "retention.cost_rows.archive_days", def: 0,
    // The floor is the widest window of a hot-only cost_rows reader
    // (test/archive-readers.d/*.json: triage-waste.js, 60 d). Every wide reader
    // reads the archive too (lib/archive-read.js). A window below 60 runs as 60.
    floorDays: COST_ARCHIVE_FLOOR_DAYS,
    archive: "cost_rows",
    ids: "SELECT rowid AS id FROM cost_rows WHERE ts < ?1 ORDER BY ts LIMIT ?2",
    sel: "SELECT * FROM cost_rows WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM cost_rows WHERE rowid IN (SELECT value FROM json_each(?1))",
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
  // BH-6825: a human decision row (staff_promotion_decisions) lives and dies
  // with its promotion, so each rule deletes it first, in the same batch.
  {
    rule: "staff_promotions.void", table: "staff_promotions", key: "retention.staff_promotions.void_days", def: 30,
    ids: "SELECT id FROM staff_promotions WHERE status = 'void' AND decided_at < ?1 ORDER BY decided_at LIMIT ?2",
    pre: ["DELETE FROM staff_promotion_decisions WHERE promotion_id IN (SELECT value FROM json_each(?1))"],
    del: "DELETE FROM staff_promotions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "staff_promotions.applied", table: "staff_promotions", key: "retention.staff_promotions.applied_days", def: 180,
    ids: "SELECT id FROM staff_promotions WHERE status = 'applied' AND decided_at < ?1 ORDER BY decided_at LIMIT ?2",
    pre: ["DELETE FROM staff_promotion_decisions WHERE promotion_id IN (SELECT value FROM json_each(?1))"],
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
  // BH-6877: the Fly idle reaper's stop and destroy rows. They hold the $/h a
  // stop saved or a destroy avoided, so each goes into fly_idle_daily first.
  // The id reads use fly_idle_stops_stopped_at and
  // fly_idle_destroys_destroyed_at; the deletes use the PRIMARY KEY.
  {
    rule: "fly_idle_stops.age", table: "fly_idle_stops", key: "retention.fly_idle_stops.days", def: 400,
    ids: "SELECT stop_id AS id FROM fly_idle_stops WHERE stopped_at < ?1 ORDER BY stopped_at LIMIT ?2",
    rollup: `INSERT INTO fly_idle_daily (day, app, action, n, usd_per_hour_sum)
             SELECT substr(stopped_at, 1, 10), app, 'stop', COUNT(*), SUM(COALESCE(usd_per_hour, 0))
               FROM fly_idle_stops WHERE stop_id IN (SELECT value FROM json_each(?1))
              GROUP BY 1, 2
             ON CONFLICT (day, app, action) DO UPDATE SET n = n + excluded.n,
               usd_per_hour_sum = usd_per_hour_sum + excluded.usd_per_hour_sum`,
    del: "DELETE FROM fly_idle_stops WHERE stop_id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "fly_idle_destroys.age", table: "fly_idle_destroys", key: "retention.fly_idle_destroys.days", def: 400,
    ids: "SELECT destroy_id AS id FROM fly_idle_destroys WHERE destroyed_at < ?1 ORDER BY destroyed_at LIMIT ?2",
    rollup: `INSERT INTO fly_idle_daily (day, app, action, n, usd_per_hour_sum)
             SELECT substr(destroyed_at, 1, 10), app, 'destroy', COUNT(*), SUM(COALESCE(usd_per_hour, 0))
               FROM fly_idle_destroys WHERE destroy_id IN (SELECT value FROM json_each(?1))
              GROUP BY 1, 2
             ON CONFLICT (day, app, action) DO UPDATE SET n = n + excluded.n,
               usd_per_hour_sum = usd_per_hour_sum + excluded.usd_per_hour_sum`,
    del: "DELETE FROM fly_idle_destroys WHERE destroy_id IN (SELECT value FROM json_each(?1))",
  },
  // Staff autonomy and delegation changes: governance history made by a human,
  // tens of rows a year. The agent page reads the newest 20, so three years
  // keep every change anyone asks about. retention.dry_run applies.
  {
    rule: "staff_autonomy_changes.age", table: "staff_autonomy_changes", key: "retention.staff_autonomy_changes.days", def: 1095,
    ids: "SELECT id FROM staff_autonomy_changes WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM staff_autonomy_changes WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-6822: one row per staff heartbeat tick, the agent page's timeline. It is
  // heartbeat history, not money (cost stays in cost_rows), so 90 days is enough.
  {
    rule: "staff_ticks.age", table: "staff_ticks", key: "retention.staff_ticks.days", def: 90,
    ids: "SELECT id FROM staff_ticks WHERE started_at < ?1 ORDER BY started_at LIMIT ?2",
    del: "DELETE FROM staff_ticks WHERE id IN (SELECT value FROM json_each(?1))",
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
  // BH-6972: a component-watch decision is a diagnostic; the audit of each
  // state change stays in alert_actions, so the row is deleted, not archived.
  {
    rule: "alert_decisions.age", table: "alert_decisions", key: "retention.alert_decisions.days", def: 90,
    ids: "SELECT id FROM alert_decisions WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM alert_decisions WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-7325: a migration-number reservation is a short claim; after 30 days its
  // number is on main, in a PR or unused, so the row is deleted, not archived.
  {
    rule: "migration_reservations.age", table: "migration_reservations", key: "retention.migration_reservations.days", def: 30,
    ids: "SELECT rowid AS id FROM migration_reservations WHERE reserved_at < ?1 ORDER BY reserved_at LIMIT ?2",
    del: "DELETE FROM migration_reservations WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // BH-8067: the PR record is a cache of GitHub-owned state; a deleted row
  // reads as unknown and one GitHub read rebuilds it. The closed delete repeats
  // the state test, so a PR reopened between the id read and the delete stays.
  {
    rule: "pr_records.closed", table: "pr_records", key: "retention.pr_records.closed_days", def: 14,
    ids: "SELECT id FROM pr_records WHERE state IN ('closed','merged') AND refreshed_at < ?1 ORDER BY state, refreshed_at LIMIT ?2",
    del: "DELETE FROM pr_records WHERE id IN (SELECT value FROM json_each(?1)) AND state IN ('closed','merged')",
  },
  {
    rule: "pr_records.age", table: "pr_records", key: "retention.pr_records.days", def: 90,
    ids: "SELECT id FROM pr_records WHERE refreshed_at < ?1 ORDER BY refreshed_at LIMIT ?2",
    del: "DELETE FROM pr_records WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-6739: a split-ticket row is the "filed once" memory; after a year a still-hot path may file again.
  {
    rule: "hotspot_tickets.age", table: "hotspot_tickets", key: "retention.hotspot_tickets.days", def: 365,
    ids: "SELECT rowid AS id FROM hotspot_tickets WHERE filed_at < ?1 ORDER BY filed_at LIMIT ?2",
    del: "DELETE FROM hotspot_tickets WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // BH-7243.0: the roadmap. Each rule copies to the archive before it deletes;
  // unbound, it deletes nothing and reports "archive not bound" only while a
  // row waits (quietUnbound).
  // The idea and wave deletes repeat the state test, so an idea restored or a
  // wave reopened between the id read and the delete stays. Waves hold
  // cost_usd (money): archived, never only deleted.
  {
    rule: "roadmap_ideas.discarded", table: "roadmap_ideas", key: "retention.roadmap_ideas.discarded_days", def: 180,
    archive: "roadmap_ideas", quietUnbound: true,
    ids: "SELECT id FROM roadmap_ideas WHERE lane = 'discarded' AND discarded_at < ?1 ORDER BY discarded_at LIMIT ?2",
    sel: "SELECT * FROM roadmap_ideas WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM roadmap_ideas WHERE id IN (SELECT value FROM json_each(?1)) AND lane = 'discarded'",
  },
  {
    rule: "roadmap_idea_events.age", table: "roadmap_idea_events", key: "retention.roadmap_idea_events.days", def: 730,
    archive: "roadmap_idea_events", quietUnbound: true,
    ids: "SELECT id FROM roadmap_idea_events WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM roadmap_idea_events WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM roadmap_idea_events WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "roadmap_waves.closed", table: "roadmap_waves", key: "retention.roadmap_waves.days", def: 365,
    archive: "roadmap_waves", quietUnbound: true,
    ids: "SELECT id FROM roadmap_waves WHERE status IN ('rejected','failed') AND updated_at < ?1 ORDER BY updated_at LIMIT ?2",
    sel: "SELECT * FROM roadmap_waves WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM roadmap_waves WHERE id IN (SELECT value FROM json_each(?1)) AND status IN ('rejected','failed')",
  },
  // BH-7722: the Tackler decision ledger is history of record: a terminal row
  // past retention.unblock_decisions.days is copied to the archive D1, then
  // deleted. A claimed or escalated row never goes (an open claim or card).
  {
    rule: "unblock_decisions.age", table: "unblock_decisions", key: "retention.unblock_decisions.days", def: 180,
    archive: "unblock_decisions", quietUnbound: true,
    ids: `SELECT id FROM unblock_decisions WHERE created_at < ?1 AND outcome NOT IN ('claimed','escalated')
           ORDER BY created_at LIMIT ?2`,
    sel: "SELECT * FROM unblock_decisions WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM unblock_decisions WHERE id IN (SELECT value FROM json_each(?1)) AND outcome NOT IN ('claimed','escalated')",
  },
  // BH-6823: staff chat. A closed operator note goes with its reply past
  // retention.staff_chat.days. A pending, held or taken note never goes.
  {
    rule: "staff_chat.age", table: "staff_chat", key: "retention.staff_chat.days", def: 365,
    ids: `SELECT id FROM staff_chat WHERE role = 'operator' AND created_at < ?1
           AND state IN ('read','unanswered','failed') ORDER BY created_at LIMIT ?2`,
    pre: ["DELETE FROM staff_chat WHERE reply_to IN (SELECT value FROM json_each(?1))"],
    del: "DELETE FROM staff_chat WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "sched_diffs.age", table: "sched_diffs", key: "retention.sched_diffs.days", def: 30,
    ids: "SELECT id FROM sched_diffs WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM sched_diffs WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "sched_ticks.age", table: "sched_ticks", key: "retention.sched_ticks.days", def: 30,
    ids: "SELECT id FROM sched_ticks WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM sched_ticks WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "sched_ready.age", table: "sched_ready", key: "retention.sched_ready.days", def: 3,
    ids: "SELECT id FROM sched_ready WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM sched_ready WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-7300: an ended docker-pool lease is coordination state with no money in
  // it; the build history stays in build_queue and the jobs ledger. An active
  // lease (ended_at NULL) is never a candidate.
  {
    rule: "docker_pool_leases.ended", table: "docker_pool_leases", key: "retention.docker_pool_leases.days", def: 30,
    ids: "SELECT id FROM docker_pool_leases WHERE ended_at < ?1 AND status <> 'active' ORDER BY ended_at LIMIT ?2",
    del: "DELETE FROM docker_pool_leases WHERE id IN (SELECT value FROM json_each(?1)) AND status <> 'active'",
  },
  // BH-7348: a docker-pool result row is a summary with no money in it (the
  // money is in cost_rows). A row the hub has not read yet is never a candidate.
  {
    rule: "docker_pool_results.age", table: "docker_pool_results", key: "retention.docker_pool_results.days", def: 30,
    ids: "SELECT id FROM docker_pool_results WHERE posted_at < ?1 AND reaped_at IS NOT NULL ORDER BY posted_at LIMIT ?2",
    del: "DELETE FROM docker_pool_results WHERE id IN (SELECT value FROM json_each(?1)) AND reaped_at IS NOT NULL",
  },
  // BH-7431: the pool's once-markers and wait clocks. The after-gate ceiling is
  // 6 h and the cap window 24 h, so a 30-day-old marker gates nothing. Reads on
  // idx_pool_markers_updated; deletes by rowid. No money in these rows.
  {
    rule: "pool_markers.age", table: "pool_markers", key: "retention.pool_markers.days", def: 30,
    ids: "SELECT rowid AS id FROM pool_markers WHERE updated_at < ?1 ORDER BY updated_at LIMIT ?2",
    del: "DELETE FROM pool_markers WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
  // BH-7595: the web_vault audit trail is history, so it is copied to the
  // archive D1 before the delete; unbound, nothing is deleted. web_vault itself
  // has no rule: a stale entry is reported, never deleted.
  {
    rule: "web_vault_audit.age", table: "web_vault_audit", key: "retention.web_vault_audit.days", def: 90,
    archive: "web_vault_audit", quietUnbound: true,
    ids: "SELECT id FROM web_vault_audit WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM web_vault_audit WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM web_vault_audit WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-7595: the hash of a web-task claim token is a short-lived credential,
  // not history; a run past its lease has no use for it.
  {
    rule: "web_vault_run_token.age", table: "web_vault_run_token", key: "retention.web_vault_run_token.days", def: 2,
    ids: "SELECT run_id AS id FROM web_vault_run_token WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM web_vault_run_token WHERE run_id IN (SELECT value FROM json_each(?1))",
  },
  // BH-7429: a pool build record is a transport copy; the hub build dir is
  // the record of the build. A row the reap read has no reader left; a row
  // nobody read means the hub took the ssh path. No money, no history.
  {
    rule: "pool_record_files.reaped", table: "pool_record_files", key: "retention.pool_record_files.reaped_days", def: 1,
    ids: "SELECT id FROM pool_record_files WHERE reaped_at IS NOT NULL AND reaped_at < ?1 ORDER BY reaped_at LIMIT ?2",
    del: "DELETE FROM pool_record_files WHERE id IN (SELECT value FROM json_each(?1)) AND reaped_at IS NOT NULL",
  },
  {
    rule: "pool_record_files.unread", table: "pool_record_files", key: "retention.pool_record_files.unread_days", def: 3,
    ids: "SELECT id FROM pool_record_files WHERE reaped_at IS NULL AND posted_at < ?1 ORDER BY posted_at LIMIT ?2",
    del: "DELETE FROM pool_record_files WHERE id IN (SELECT value FROM json_each(?1)) AND reaped_at IS NULL",
  },
  // BH-7732: an OTP row is a short-lived secret with no reader after minutes; not money or history.
  {
    rule: "otp_messages.age", table: "otp_messages", key: "retention.otp_messages.days", def: 1,
    ids: "SELECT id FROM otp_messages WHERE received_at < ?1 ORDER BY received_at LIMIT ?2",
    del: "DELETE FROM otp_messages WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-7934.2: a finished onboarding run (done, failed, cancelled) and its 7
  // steps have no reader after the setup screen; not money or history. The
  // pre and the delete re-check the state, so a run a retry set back to
  // queued after the id read keeps its row and its steps.
  {
    rule: "onboarding_runs.finished", table: "onboarding_runs", key: "onboarding_runs_retention_days", def: 30,
    ids: `SELECT id FROM onboarding_runs WHERE state IN ('done','failed','cancelled') AND updated_at < ?1
          ORDER BY updated_at LIMIT ?2`,
    pre: [`DELETE FROM onboarding_steps WHERE run_id IN
           (SELECT id FROM onboarding_runs WHERE id IN (SELECT value FROM json_each(?1))
              AND state IN ('done','failed','cancelled'))`],
    del: "DELETE FROM onboarding_runs WHERE id IN (SELECT value FROM json_each(?1)) AND state IN ('done','failed','cancelled')",
  },
  // BH-7598: a web-task human step is a short-lived request that can hold a
  // code ciphertext; not money or history. The window outlives the answer TTL.
  {
    rule: "web_task_human_step.age", table: "web_task_human_step", key: "retention.web_task_human_step.days", def: 30,
    ids: "SELECT id FROM web_task_human_step WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM web_task_human_step WHERE id IN (SELECT value FROM json_each(?1))",
  },
];

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

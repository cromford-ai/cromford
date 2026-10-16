-- ── BH-6822: the staff agent activity timeline ──────────────────────────────
-- staff_ticks is one row per heartbeat tick of bin/staff.sh that got past the
-- agent lock. The tick writes it at exit through POST /api/staff/ticks
-- (src/routes/staff-activity.js). tick_key is the natural key
-- (<agent>-<start second>-<pid>): a replay with the same body is a no-op, a
-- different body is 409. phase names where the tick stopped. cost_run_id is
-- `staff-tick:<tick_key>` when the tick made a model call (agent-call writes
-- it into cost_rows.run_id as COST_RUN_ID), else NULL. duration_s is computed
-- by the route from started_at and ended_at.
--
-- INDEXES, one per query (src/routes/staff-activity.js, staff-screen.js,
-- retention.js):
--   idx_staff_ticks_agent_started      the timeline's tick read (agent=?, the
--                                      cursor on started_at, ORDER BY
--                                      started_at DESC, id DESC) and the
--                                      last-tick seek per agent
--   idx_staff_ticks_started            the retention id read
--   idx_staff_findings_agent_claimed   finding.claimed events
--   idx_staff_findings_agent_updated   finding.recorded events
--   idx_staff_outcomes_agent_resolved  outcome events
--   idx_staff_decisions_agent_created  decision events
--   idx_archie_decisions_created       Archie's decision events
--   idx_cost_rows_run_id               the per-tick cost lookup. cost_rows.run_id
--                                      is on the live table since 2026-09-14
--                                      (ensureColumns), and routes/lanes.js
--                                      already reads it there.
--
-- RETENTION (BH-6750 job, src/routes/retention.js, rule staff_ticks.age):
-- heartbeat history, not money. Cost stays in cost_rows. A tick older than
-- retention.staff_ticks.days (90) goes. About 670 rows a day for 7 agents.
-- retention.dry_run (seed 1) applies: the first runs only count.
--
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS staff_ticks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tick_key TEXT NOT NULL UNIQUE,
  agent TEXT NOT NULL,
  started_at TEXT NOT NULL,
  ended_at TEXT NOT NULL,
  duration_s INTEGER NOT NULL,
  phase TEXT NOT NULL CHECK (phase IN ('roster','soul','collect','claim','model','act','done')),
  collector_rc INTEGER,
  collector_s INTEGER,
  model_rc INTEGER,
  collected INTEGER NOT NULL DEFAULT 0,
  new_items INTEGER NOT NULL DEFAULT 0,
  deferred INTEGER NOT NULL DEFAULT 0,
  model_calls INTEGER NOT NULL DEFAULT 0,
  digested INTEGER NOT NULL DEFAULT 0,
  filed INTEGER NOT NULL DEFAULT 0,
  refused INTEGER NOT NULL DEFAULT 0,
  unsupported INTEGER NOT NULL DEFAULT 0,
  failed INTEGER NOT NULL DEFAULT 0,
  held INTEGER NOT NULL DEFAULT 0,
  cost_run_id TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_staff_ticks_agent_started ON staff_ticks(agent, started_at, id);
CREATE INDEX IF NOT EXISTS idx_staff_ticks_started ON staff_ticks(started_at);
CREATE INDEX IF NOT EXISTS idx_staff_findings_agent_claimed ON staff_findings(agent, claimed_at, id);
CREATE INDEX IF NOT EXISTS idx_staff_findings_agent_updated ON staff_findings(agent, updated_at, id);
CREATE INDEX IF NOT EXISTS idx_staff_outcomes_agent_resolved ON staff_outcomes(agent, resolved_at, id);
CREATE INDEX IF NOT EXISTS idx_staff_decisions_agent_created ON staff_decisions(agent, created_at, id);
CREATE INDEX IF NOT EXISTS idx_archie_decisions_created ON archie_decisions(created_at, id);
CREATE INDEX IF NOT EXISTS idx_cost_rows_run_id ON cost_rows(run_id);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.staff_ticks.days','90','BH-6822: days a staff heartbeat tick row is kept (0 = off). Heartbeat history, not money: cost stays in cost_rows.','seed','2026-10-15T00:00:00Z');

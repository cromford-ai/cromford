-- ── BH-9127: staff_turns, Archie's activity rows on the team screen ─────────
-- One row per Archie turn: every bin/orchestrate.sh turn past its claim, and a
-- bin/archie.sh tick that acted (beats or model calls). bin/lib/archie-hb.sh
-- writes it through POST /api/staff/turns (src/routes/staff-turns.js) after the
-- reply is delivered. turn_key is the natural key (archie-<kind>-<epoch>-<pid>):
-- a replay with the same body is a no-op, another body is 409. summary is one
-- line, token-scrubbed and cut to staff.turns.summary_max_chars. cost_run_id is
-- `staff-turn:<turn_key>` when the turn's model calls carry it as COST_RUN_ID,
-- else NULL; the turn's cost is read at page time by that run_id, never stored.
--
-- INDEXES, one per query:
--   idx_staff_turns_agent_started  the timeline's turn read (agent=?, the
--                                  cursor on started_at, ORDER BY started_at
--                                  DESC, id DESC) in src/routes/staff-activity.js
--   idx_staff_turns_started        the retention id read (started_at < ?1)
--   The turn cost lookup by run_id uses idx_cost_rows_run_id (BH-6822 fragment).
--   The roster's spend per lane (src/routes/staff-screen.js) uses the
--   cost_rows (lane_id, ts) index. That index is NOT declared or named here:
--   lane_id is an added column, and core.d/0000-added-indexes.js creates it
--   through ensureColumns (the 0002-base-rest.sql note, #2473).
--
-- SETTINGS (each a knob; the code fallback names its row):
--   staff.spend.lane_map           agent -> list of cost_rows.lane_id, added to
--                                  each staff agent's staff_lanes rows
--   staff.spend.window_days        the long SPEND window (1..60, the cost_rows
--                                  hot floor COST_ARCHIVE_FLOOR_DAYS; fallback 7)
--   staff.turns.summary_in_max     the longest summary POST /api/staff/turns
--                                  accepts (a positive integer, fallback 2000);
--                                  bin/lib/archie-hb.sh cuts to it too
--   staff.turns.summary_max_chars  stored summary length (1..summary_in_max,
--                                  fallback 200)
--   retention.staff_turns.days     the retention window (fallback 90)
--
-- RETENTION (BH-6750 job, src/routes/retention.d/bh-9127-staff-turns.js, rule
-- staff_turns.age): activity history, not money. Cost stays in cost_rows. A
-- turn older than retention.staff_turns.days (90) goes. retention.dry_run
-- (seed 1) applies: the first runs only count, and each run writes its audit row.
--
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS staff_turns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  turn_key TEXT NOT NULL UNIQUE,
  agent TEXT NOT NULL,
  started_at TEXT NOT NULL,
  ended_at TEXT NOT NULL,
  trigger TEXT NOT NULL CHECK (trigger IN ('telegram','slack','dash','beat','sweep','follow-up')),
  summary TEXT NOT NULL,
  link_url TEXT,
  outcome TEXT NOT NULL CHECK (outcome IN ('answered','no_reply','stopped','acted')),
  cost_run_id TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_staff_turns_agent_started ON staff_turns(agent, started_at, id);
CREATE INDEX IF NOT EXISTS idx_staff_turns_started ON staff_turns(started_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.spend.lane_map','{"archie":["orc-monitor","archie","archie-research","archie-cards","archie-learn"]}','BH-9127: agent -> cost_rows.lane_id list for the /staff SPEND column, added to each staff agent''s staff_lanes rows. The shared lane staff is attributed per agent through staff_ticks, never listed here.','seed','2026-11-06T00:00:00Z'),
  ('staff.spend.window_days','7','BH-9127: the long SPEND window on /staff in days (1..60; 60 is the cost_rows hot floor). Code fallback 7.','seed','2026-11-06T00:00:00Z'),
  ('staff.turns.summary_in_max','2000','BH-9127: the longest turn summary POST /api/staff/turns accepts (a longer one is a 400). bin/lib/archie-hb.sh cuts to this row too. Code fallback 2000.','seed','2026-11-06T00:00:00Z'),
  ('staff.turns.summary_max_chars','200','BH-9127: characters of a turn summary kept by POST /api/staff/turns (1..staff.turns.summary_in_max). Code fallback 200.','seed','2026-11-06T00:00:00Z'),
  ('retention.staff_turns.days','90','BH-9127: days an agent turn row is kept (0 = off). Activity history, not money: cost stays in cost_rows.','seed','2026-11-06T00:00:00Z');

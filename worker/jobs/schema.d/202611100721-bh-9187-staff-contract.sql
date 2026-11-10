-- ── BH-9187: the staff agent contract (C0) ─────────────────────────────────
-- Every staff agent owns ONE metric and is judged by whether it moved. This
-- fragment holds the three ledgers of that contract and its settings rows.
-- Note: docs/notes/2026-11-06-BH-9187-staff-contract.md.
--
-- staff_finding_seen: one row per staff_findings fingerprint. The claim route
-- (POST /api/staff/findings/claim) upserts it on every claim that resolves to
-- a row: a new claim inserts seen_count 1, a repeat adds 1 and moves
-- last_checked_at. A repeat writes no new finding. agent is the row owner.
-- A side table, not a column on staff_findings: D1 has no ADD COLUMN IF NOT
-- EXISTS, and every fragment must re-apply as a no-op.
--
-- staff_lever_actions: one row per lever action (POST /api/staff/levers/actions).
-- action_key is sha256(agent|lever|key), so a retried action is one row.
-- metric_before is the metric when the action ran. A sample at least
-- staff.settle_hours after acted_at settles it (POST /api/staff/levers/metric):
-- metric_after is the sample, moved = 1 when the sample is lower (every ticket
-- metric is lower-is-better). A dry run (dry_run = 1) never settles.
--
-- staff_metric_samples: append-only metric readings per (agent, metric).
--
-- INDEXES. Each query and the index that serves it:
--   claim upsert, seen read           WHERE fingerprint=?  PK of staff_finding_seen
--   per-agent seen read               WHERE agent=? ORDER BY last_checked_at
--                                     idx_staff_finding_seen_agent
--   seen retention (orphans)          WHERE last_checked_at < ?1 (+ PK lookup in
--                                     staff_findings by fingerprint, UNIQUE)
--                                     idx_staff_finding_seen_checked
--   action insert / key read          WHERE action_key=?   UNIQUE(action_key)
--   scorecard actions in window       WHERE agent=? AND acted_at >= ?
--                                     idx_staff_lever_actions_agent
--   settle UPDATE                     WHERE agent=? AND metric=? AND settled_at
--                                     IS NULL AND dry_run=0 AND acted_at <= ?
--                                     idx_staff_lever_actions_due (partial)
--   action retention                  WHERE settled_at < ?1 (settled only)
--                                     idx_staff_lever_actions_settled (partial)
--   scorecard metric now / then       WHERE agent=? AND metric=? AND
--                                     sampled_at <= ? ORDER BY sampled_at DESC
--                                     idx_staff_metric_samples_agent
--   sample retention                  WHERE sampled_at < ?1
--                                     idx_staff_metric_samples_at
--
-- RETENTION (retention.d/bh-9187-staff-contract.js, the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies):
--   staff_metric_samples  older than retention.staff_metric_samples.days (90)
--   staff_lever_actions   SETTLED rows older than retention.staff_lever_actions.days
--                         (365); an unsettled row is never removed
--   staff_finding_seen    a row whose finding is gone, checked longer ago than
--                         retention.staff_finding_seen.orphan_days (1)
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS staff_finding_seen (
  fingerprint TEXT PRIMARY KEY CHECK (length(fingerprint) = 64),
  agent TEXT NOT NULL,
  seen_count INTEGER NOT NULL DEFAULT 1,
  first_seen_at TEXT NOT NULL,
  last_checked_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_staff_finding_seen_agent ON staff_finding_seen(agent, last_checked_at);
CREATE INDEX IF NOT EXISTS idx_staff_finding_seen_checked ON staff_finding_seen(last_checked_at);

CREATE TABLE IF NOT EXISTS staff_lever_actions (
  id INTEGER PRIMARY KEY,
  action_key TEXT NOT NULL UNIQUE,
  agent TEXT NOT NULL,
  lever TEXT NOT NULL,
  target TEXT NOT NULL,
  dry_run INTEGER NOT NULL CHECK (dry_run IN (0, 1)),
  metric TEXT NOT NULL,
  metric_before REAL NOT NULL,
  detail TEXT,
  acted_at TEXT NOT NULL,
  settled_at TEXT,
  metric_after REAL,
  moved INTEGER CHECK (moved IN (0, 1))
);
CREATE INDEX IF NOT EXISTS idx_staff_lever_actions_agent ON staff_lever_actions(agent, acted_at);
CREATE INDEX IF NOT EXISTS idx_staff_lever_actions_due ON staff_lever_actions(agent, metric, acted_at)
  WHERE settled_at IS NULL AND dry_run = 0;
CREATE INDEX IF NOT EXISTS idx_staff_lever_actions_settled ON staff_lever_actions(settled_at)
  WHERE settled_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS staff_metric_samples (
  id INTEGER PRIMARY KEY,
  agent TEXT NOT NULL,
  metric TEXT NOT NULL,
  value REAL NOT NULL,
  detail TEXT,
  sampled_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_staff_metric_samples_agent ON staff_metric_samples(agent, metric, sampled_at);
CREATE INDEX IF NOT EXISTS idx_staff_metric_samples_at ON staff_metric_samples(sampled_at);

-- The contract rows, one statement per agent. level is observe | file | act;
-- the code fallback is observe (bin/lib/staff-contract.sh staff_level).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.inspector.level','observe','BH-9187: inspector contract level: observe (digest only) | file (files tickets, file_max_day a day) | act (its listed levers). Fallback observe.','seed','2026-11-06T21:15:00Z'),
  ('staff.inspector.metric','hours_behind_main','BH-9187: the one metric inspector owns (lower is better).','seed','2026-11-06T21:15:00Z'),
  ('staff.inspector.target','2','BH-9187: inspector target for hours_behind_main.','seed','2026-11-06T21:15:00Z'),
  ('staff.inspector.file_max_day','3','BH-9187: tickets inspector may file per UTC day at level file or act. Fallback 3.','seed','2026-11-06T21:15:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.clerk.level','observe','BH-9187: clerk contract level: observe | file | act. Fallback observe.','seed','2026-11-06T21:15:00Z'),
  ('staff.clerk.metric','needs_count','BH-9187: the one metric clerk owns (lower is better).','seed','2026-11-06T21:15:00Z'),
  ('staff.clerk.target','300','BH-9187: clerk target for needs_count.','seed','2026-11-06T21:15:00Z'),
  ('staff.clerk.file_max_day','3','BH-9187: tickets clerk may file per UTC day at level file or act. Fallback 3.','seed','2026-11-06T21:15:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.dispatcher.level','observe','BH-9187: dispatcher contract level: observe | file | act. Fallback observe.','seed','2026-11-06T21:15:00Z'),
  ('staff.dispatcher.metric','ready_unqueued_2h','BH-9187: the one metric dispatcher owns (lower is better).','seed','2026-11-06T21:15:00Z'),
  ('staff.dispatcher.target','0','BH-9187: dispatcher target for ready_unqueued_2h.','seed','2026-11-06T21:15:00Z'),
  ('staff.dispatcher.file_max_day','3','BH-9187: tickets dispatcher may file per UTC day at level file or act. Fallback 3.','seed','2026-11-06T21:15:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.watchman.level','observe','BH-9187: watchman contract level: observe | file | act. Fallback observe.','seed','2026-11-06T21:15:00Z'),
  ('staff.watchman.metric','live_unrotated_secrets','BH-9187: the one metric watchman owns (lower is better).','seed','2026-11-06T21:15:00Z'),
  ('staff.watchman.target','0','BH-9187: watchman target for live_unrotated_secrets.','seed','2026-11-06T21:15:00Z'),
  ('staff.watchman.file_max_day','3','BH-9187: tickets watchman may file per UTC day at level file or act. Fallback 3.','seed','2026-11-06T21:15:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.quartermaster.level','observe','BH-9187: quartermaster contract level: observe | file | act. Fallback observe.','seed','2026-11-06T21:15:00Z'),
  ('staff.quartermaster.metric','orphan_usd_day','BH-9187: the one metric quartermaster owns (lower is better).','seed','2026-11-06T21:15:00Z'),
  ('staff.quartermaster.target','0','BH-9187: quartermaster target for orphan_usd_day.','seed','2026-11-06T21:15:00Z'),
  ('staff.quartermaster.file_max_day','3','BH-9187: tickets quartermaster may file per UTC day at level file or act. Fallback 3.','seed','2026-11-06T21:15:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.millwright.level','observe','BH-9187: millwright contract level: observe | file | act. Fallback observe.','seed','2026-11-06T21:15:00Z'),
  ('staff.millwright.metric','failed_bakes_and_broken_boxes','BH-9187: the one metric millwright owns (lower is better).','seed','2026-11-06T21:15:00Z'),
  ('staff.millwright.target','0','BH-9187: millwright target for failed_bakes_and_broken_boxes.','seed','2026-11-06T21:15:00Z'),
  ('staff.millwright.file_max_day','3','BH-9187: tickets millwright may file per UTC day at level file or act. Fallback 3.','seed','2026-11-06T21:15:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.archivist.level','observe','BH-9187: archivist contract level: observe | file | act. Fallback observe.','seed','2026-11-06T21:15:00Z'),
  ('staff.archivist.metric','causes_fixed_by_hand_twice','BH-9187: the one metric archivist owns (lower is better).','seed','2026-11-06T21:15:00Z'),
  ('staff.archivist.target','0','BH-9187: archivist target for causes_fixed_by_hand_twice.','seed','2026-11-06T21:15:00Z'),
  ('staff.archivist.file_max_day','3','BH-9187: tickets archivist may file per UTC day at level file or act. Fallback 3.','seed','2026-11-06T21:15:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.scorecard_days','7','BH-9187: the scorecard window in days when the caller gives no days= (metric now vs this many days ago). Fallback 7.','seed','2026-11-06T21:15:00Z'),
  ('staff.scorecard_days_max','30','BH-9187: the largest days= the scorecard accepts (a larger one is 400). Fallback 30.','seed','2026-11-06T21:15:00Z'),
  ('staff.settle_hours','24','BH-9187: hours after a lever action before a metric sample settles it (moved or not). Fallback 24.','seed','2026-11-06T21:15:00Z'),
  ('retention.staff_metric_samples.days','90','BH-9187: days a staff metric sample is kept (0 = off).','seed','2026-11-06T21:15:00Z'),
  ('retention.staff_lever_actions.days','365','BH-9187: days a SETTLED staff lever action is kept (0 = off). An unsettled one is never removed.','seed','2026-11-06T21:15:00Z'),
  ('retention.staff_finding_seen.orphan_days','1','BH-9187: days a staff_finding_seen row whose finding is gone is kept (0 = off).','seed','2026-11-06T21:15:00Z');

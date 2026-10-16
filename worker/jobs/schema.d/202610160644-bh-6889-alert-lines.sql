-- BH-6889 (BH-6881.5): alert lines that a lane-run machine raised. A machine
-- has no logs/ALERTS.log of its own, so bin/alert-line.sh (LANE_RUN_ID set)
-- posts the line here through bin/lib/alert-line-remote.sh (alr_post). The
-- hub's bin/lane-snapshot-publish.sh (alr_apply) reads the unapplied rows,
-- replays each one through bin/alert-line.sh, and marks them applied.
-- Routes: worker/jobs/src/routes/alert-lines.js. Contract:
-- docs/notes/2026-10-16-BH-6889-mc-manifest-alert-lines.md. Additive only.
--
-- dedup_key is sha256(lane|project|run_id|line), computed by the worker: a
-- machine that posts the same line twice in one run makes one row.
--
-- Index per query:
--   insert ON CONFLICT(dedup_key) DO NOTHING                     ux_alert_lines_dedup
--   SELECT id WHERE dedup_key=?                                  ux_alert_lines_dedup
--   GET WHERE applied_at IS NULL ORDER BY id LIMIT ?             idx_alert_lines_applied
--   mark WHERE applied_at IS NULL AND id IN (json_each)          PRIMARY KEY
--   retention WHERE applied_at < ? ORDER BY applied_at LIMIT ?   idx_alert_lines_applied
--   retention WHERE applied_at IS NULL AND created_at < ?
--             ORDER BY id LIMIT ?                                idx_alert_lines_applied
--
-- Retention: rules alert_lines.applied (retention.alert_lines.applied_days, 7)
-- and alert_lines.unapplied (retention.alert_lines.unapplied_days, 30) in
-- worker/jobs/src/routes/retention.js. Operational lines, not money or
-- history: the hub ALERTS.log holds the replayed copy, so the rows are deleted.
CREATE TABLE IF NOT EXISTS alert_lines (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- AUTOINCREMENT: never reuse an id after retention empties the table
  lane TEXT NOT NULL,
  project TEXT NOT NULL,
  line TEXT NOT NULL,
  stamp TEXT,
  severity TEXT,
  alertid TEXT,
  run_id TEXT,
  dedup_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  applied_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_alert_lines_dedup ON alert_lines (dedup_key);
CREATE INDEX IF NOT EXISTS idx_alert_lines_applied ON alert_lines (applied_at, id);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.alert_lines.applied_days','7','BH-6889: days an applied alert_lines row is kept after the hub replayed it (0 = off)','seed','2026-10-16T00:00:00Z'),
  ('retention.alert_lines.unapplied_days','30','BH-6889: days an alert_lines row the hub never replayed is kept (0 = off)','seed','2026-10-16T00:00:00Z'),
  ('alert_lines.apply_max','200','BH-6889: unapplied alert lines bin/lane-snapshot-publish.sh replays per tick (1..500); the code default is 200','seed','2026-10-16T00:00:00Z');

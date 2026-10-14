-- BH-6127 (BH-6047 part 4 of 5): the lane-run queue-wait alert and the hub
-- load that Mission Control shows beside the lane-run metrics.
--
-- lane_run_wait_alerts is the breach latch, one row per lane whose oldest
-- queued run waits over lane_run.wait_alert_min. POST /api/lane-runs/wait-tick
-- counts the consecutive over ticks and deletes the row when the lane is no
-- longer over; POST /api/lane-runs/wait-ack stamps alerted_at after
-- bin/lane-run-wait-alert.sh wrote the alert. So the table holds at most one
-- row per lane, and alerted_at is set only after the send.
CREATE TABLE IF NOT EXISTS lane_run_wait_alerts (
  lane TEXT PRIMARY KEY,
  over_ticks INTEGER NOT NULL,
  first_over_at TEXT NOT NULL,
  last_wait_s INTEGER NOT NULL,
  last_tick_at TEXT NOT NULL,
  alerted_at TEXT
);
-- The hub's 1-minute load average, written by the same wait tick. One row per
-- box; GET /api/lane-runs/metrics reads the newest and shows its age.
CREATE TABLE IF NOT EXISTS lane_run_hub_load (
  box TEXT PRIMARY KEY,
  load1 REAL,
  reported_at TEXT NOT NULL
);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_run.wait_alert_min','10','BH-6127: minutes the oldest queued lane run may wait before bin/lane-run-wait-alert.sh alerts, on 2 consecutive ticks; equal is not over (1..1440); the code default is 10','seed','2026-10-12T00:00:00Z');

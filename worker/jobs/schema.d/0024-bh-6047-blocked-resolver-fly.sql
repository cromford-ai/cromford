-- BH-6128 (BH-6047 part 5 of 5): blocked-resolver inputs off the hub. The hub
-- publishes one read-only tar.gz per (lane, project) as base64 parts
-- (routes/lane-snapshots.js): parts are staged in lane_snapshot_parts under
-- their sha, then ONE commit statement flips lane_snapshots to that sha. A Fly
-- machine fetches the current generation, runs the lane, and posts what it
-- changed as one row in lane_snapshot_writebacks; the hub applies the rows in
-- id order and acks them. Timestamps are ISO YYYY-MM-DDTHH:MM:SSZ, so a
-- string compare on published_at / applied_at is a time compare.
CREATE TABLE IF NOT EXISTS lane_snapshots (
  lane TEXT NOT NULL,
  project TEXT NOT NULL,
  sha TEXT NOT NULL,
  parts INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  applied_through INTEGER NOT NULL DEFAULT 0,
  published_at TEXT NOT NULL,
  PRIMARY KEY (lane, project)
);
CREATE TABLE IF NOT EXISTS lane_snapshot_parts (
  lane TEXT NOT NULL,
  project TEXT NOT NULL,
  sha TEXT NOT NULL,
  n INTEGER NOT NULL,
  b64 TEXT NOT NULL,
  PRIMARY KEY (lane, project, sha, n)
);
-- A replay of the same (lane, project, run_id, sha) is the same row.
CREATE TABLE IF NOT EXISTS lane_snapshot_writebacks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  lane TEXT NOT NULL,
  project TEXT NOT NULL,
  run_id TEXT NOT NULL,
  machine TEXT NOT NULL,
  sha TEXT NOT NULL,
  b64 TEXT NOT NULL,
  created_at TEXT NOT NULL,
  applied_at TEXT,
  rejected_at TEXT,
  UNIQUE (lane, project, run_id, sha)
);
CREATE INDEX IF NOT EXISTS idx_lane_snapshot_writebacks_lp ON lane_snapshot_writebacks(lane, project, id);
-- The knobs only. This fragment does NOT place blocked-resolver on Fly: no
-- machine runs bin/lane-run-worker.sh yet (BH-6125 heartbeat and BH-6126
-- fleet). The flip (lane_placement.blocked-resolver=fly) ships as its own
-- fragment after those land, with a stats probe that shows a live claimer.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_snapshot.max_age_s','1200','BH-6128: seconds; a machine refuses a lane snapshot older than this; the code default is 1200','seed','2026-10-12T00:00:00Z'),
  ('lane_snapshot.max_bytes','33554432','BH-6128: the largest gz lane snapshot the hub publishes per project, in bytes; the code default is 33554432','seed','2026-10-12T00:00:00Z'),
  ('lane_snapshot.builds_days','30','BH-6128: build records younger than this many days ride in the lane snapshot; the code default is 30','seed','2026-10-12T00:00:00Z'),
  ('lane_snapshot.max_pending','500','BH-6128: the most write-backs a lane snapshot GET lists before it answers truncated (1..10000); the code default is 500','seed','2026-10-12T00:00:00Z');

-- BH-6126 (BH-6047 part 3 of 5): the lane-run Fly fleet. bin/lane-fleet.sh
-- (hub, every minute) starts and stops machines in the Fly app `lane-run`, and
-- records each one here through routes/lane-fleet.js, keyed on the Fly machine
-- id. A `starting` row is the in-flight start the next tick reads before it
-- spends again; costed_until is the last whole minute a cost_rows row covers
-- (box lane-run-<machine_id>, row_hash lane-fleet:<machine_id>:<minute>).
-- failed_at is the last time the tick stopped a start that made no claim; the
-- tick starts nothing for lane_fleet.failed_start_backoff_s after it.
-- Timestamps are ISO YYYY-MM-DDTHH:MM:SSZ, so a string compare is a time compare.
CREATE TABLE IF NOT EXISTS lane_machines (
  machine_id TEXT PRIMARY KEY,
  app TEXT NOT NULL DEFAULT 'lane-run',
  state TEXT NOT NULL CHECK (state IN ('starting','started','stopped','destroyed')),
  cpu_kind TEXT,
  cpus INTEGER,
  memory_mb INTEGER,
  started_at TEXT NOT NULL,
  stopped_at TEXT,
  costed_until TEXT,
  failed_at TEXT,
  updated_at TEXT NOT NULL,
  actor TEXT
);
CREATE INDEX IF NOT EXISTS idx_lane_machines_state ON lane_machines(state, started_at);
-- The fleet's knobs. bin/lane-fleet.sh reads each through setting_get and uses
-- the code default named in the note when the row is missing or out of range.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_fleet.warm_floor','1','BH-6126: lane-run machines bin/lane-fleet.sh keeps started even with an empty queue (0..100); the code default is 1','seed','2026-10-12T00:00:00Z'),
  ('lane_fleet.scale_up_wait_s','60','BH-6126: seconds the oldest queued lane run may wait before bin/lane-fleet.sh starts one more machine; equal is not over (0..86400); the code default is 60','seed','2026-10-12T00:00:00Z'),
  ('lane_fleet.idle_stop_s','600','BH-6126: seconds a lane-run machine may sit idle before bin/lane-fleet.sh stops it, never below the warm floor (60..86400); the code default is 600','seed','2026-10-12T00:00:00Z'),
  ('lane_fleet.max_machines','0','BH-6126: most lane-run machines started or starting at once; 0 = no ceiling (0..1000); the code default is 0','seed','2026-10-12T00:00:00Z'),
  ('lane_fleet.vm_size','shared-cpu-2x','BH-6126: flyctl --vm-size of a new lane-run machine ([a-z0-9-]+); the code default is shared-cpu-2x','seed','2026-10-12T00:00:00Z'),
  ('lane_fleet.vm_memory_mb','2048','BH-6126: flyctl --vm-memory (MB) of a new lane-run machine (256..65536); the code default is 2048','seed','2026-10-12T00:00:00Z'),
  ('lane_fleet.start_grace_s','180','BH-6126: seconds a started lane-run machine with no claim yet counts as a start in flight (30..3600); the code default is 180','seed','2026-10-12T00:00:00Z'),
  ('lane_fleet.failed_start_backoff_s','900','BH-6126: seconds bin/lane-fleet.sh starts no machine after it stopped a start that made no claim (60..86400); the code default is 900','seed','2026-10-12T00:00:00Z'),
  ('lane_fleet.image','registry.fly.io/lane-run:latest','BH-6126: image of a new lane-run machine, the label flyctl deploy -c fly/lane-run.toml pushes. Only a tag or digest of registry.fly.io/lane-run is used, because the machine gets the lane-run Fly secrets; any other value uses the code default registry.fly.io/lane-run:latest','seed','2026-10-12T00:00:00Z');

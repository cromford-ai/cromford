-- BH-6495 (BH-6047.5): merge-conductor per-PR workers on lane-run machines.
-- The hub reads one PR's lane_runs rows (project <project>.<pr>.<head12>) by
-- a project range before it enqueues; this index makes that a range scan, not
-- a scan of every row of the lane.
CREATE INDEX IF NOT EXISTS idx_lane_runs_lane_project ON lane_runs(lane, project, id);
-- The switch ships OFF. conductor_workers_on_fly.<project> wins over the fleet
-- row when present; only the exact value 1 is on (bin/lib/mc/fly-workers.sh).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conductor_workers_on_fly','0','BH-6495: 1 = the hub conductor enqueues one merge-conductor-pr lane_runs row per PR and starts no local worker; conductor_workers_on_fly.<project> wins when present; anything but 1, no row or an outage is off; the code default is off','seed','2026-10-14T00:00:00Z'),
  ('lane_run.term_grace_s','20','BH-6495: seconds bin/lane-run-worker.sh waits for a TERMed run to stop before it kills the run and releases the row (1..25, under the 30 s Fly stop grace); the code default is 20','seed','2026-10-14T00:00:00Z');

-- ── BH-7716: the dedicated lane host (fly-dedicated) as settings rows ───────
-- lane_dedicated.lanes: the lanes a lane_placement row may place on the
-- dedicated Fly machine (value `fly-dedicated`). bin/lib/lane-placement.sh and
-- worker/jobs/src/lib/lane-box-placement.js read it; no row = the same list in
-- code. lane_run.warm_refresh_s: how often a warm-clone worker fetches every
-- repo. The group row lane_fleet.group.dedicated (the machine) and the
-- lane_placement rows (the flip) are NOT written here: both are operator
-- writes in the go-live steps of
-- docs/notes/2026-10-20-BH-7716-dedicated-lane-host.md, so the merge starts no
-- fleet pass and changes no placement.
-- No table is created here. INSERT OR IGNORE: an operator's row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_dedicated.lanes','merge-conductor,blocked-resolver','BH-7716: the lanes a lane_placement row may place fly-dedicated (comma list)','seed','2026-10-20T00:00:00Z'),
  ('lane_run.warm_refresh_s','300','BH-7716: seconds between two fetches of every warm clone on a warm-clone machine (60..3600)','seed','2026-10-20T00:00:00Z');

-- BH-6894: pr-url-reconcile runs per project through pl_dispatch, and it has a
-- run-inputs manifest pair. Its placement is seeded hub. One settings row, no
-- table (so no index and no retention rule apply). The flip to fly is a data
-- change after a proof run, and after the jobs-API alert lines (#6889).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.pr-url-reconcile','hub','BH-6894: where bin/pr-url-reconcile.sh --dispatch runs each project (hub or fly); seeded hub. Set fly only after a proof run and #6889; no row or an outage is hub','seed','2026-10-15T00:00:00Z');

-- BH-6942 (lead review of #6960): a claim that carries skip_prefixes ends the
-- queued rows it refuses once they waited this long (routes/lane-runs.js
-- REFUSED_SQL), so a row of a repo no machine can read is never queued forever.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_run.refused_max_wait_s','600','BH-6942: seconds a lane run refused at claim (skip_prefixes) may wait queued before that claim ends it as died, prof withdrawn refused-at-claim (0..86400; 0 = never end it); the hub then works the PR (no-capacity); the code default is 600','seed','2026-10-16T00:00:00Z');

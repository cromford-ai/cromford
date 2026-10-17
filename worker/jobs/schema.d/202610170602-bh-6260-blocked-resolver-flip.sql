-- BH-6260: the flip. blocked-resolver runs on the Fly lane machines
-- (BH-6125 lease, BH-6126 fleet, BH-6128 inputs). Gate before the merge: a
-- live claimer in GET /api/lane-runs/stats?lane=blocked-resolver and
-- GET /api/lane-fleet/machines. KILL KNOB: set the row
-- lane_placement.blocked-resolver to hub. The lane returns to the hub on the
-- next dispatch, with no deploy. INSERT OR IGNORE keeps an operator value.
-- lane_snapshot.file_max is the largest file a lane snapshot or a write-back
-- carries (bin/lib/lane-run-inputs.sh); lane_snapshot.prune_after_s is how
-- long an applied or rejected write-back row stays (routes/lane-snapshots.js).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.blocked-resolver','fly','BH-6260: blocked-resolver runs on the Fly lane machines; set hub to return it to the hub with no deploy','seed','2026-10-14T00:00:00Z'),
  ('lane_snapshot.file_max','262144','BH-6260: bytes; a file over this stays out of a lane snapshot and its write-back and is logged once (1..1000000); the code default is 262144','seed','2026-10-14T00:00:00Z'),
  ('lane_snapshot.prune_after_s','604800','BH-6260: seconds an applied or rejected lane write-back row stays before the ack prunes it (3600..7776000); the code default is 604800','seed','2026-10-14T00:00:00Z');

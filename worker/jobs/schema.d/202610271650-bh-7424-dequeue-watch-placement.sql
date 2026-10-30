-- BH-7424: where bin/dequeue-watch.sh --dispatch runs its project runs
-- (bin/lib/lane-placement.sh). Seeded hub: the behaviour of today, one process
-- per project on the hub. bin/lane-move.sh flips a `hub` row by actor `seed`
-- to fly after its gates, and moves it back when the hour after does not hold.
-- No table is created here, so no index and no retention rule apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.dequeue-watch','hub','BH-7424: hub or fly; the dequeue-watch project runs. Seeded hub; bin/lane-move.sh flips it after its gates','seed','2026-10-19T14:36:00Z');

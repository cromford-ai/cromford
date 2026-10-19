-- BH-7423 (part of #7397): where bin/stuck-work.sh --dispatch runs its project
-- runs (bin/lib/lane-placement.sh). Seeded hub: the behaviour of today, one
-- process per project on the hub. bin/lane-move.sh gate g1 needs this row,
-- hub by actor seed, before it flips the lane to fly after its proof gates.
-- No table is created here, so no index and no retention rule apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.stuck-work','hub','BH-7423: hub or fly; the stuck-work project runs. Seeded hub; bin/lane-move.sh flips it to fly after its proof gates','seed','2026-10-19T14:44:00Z');

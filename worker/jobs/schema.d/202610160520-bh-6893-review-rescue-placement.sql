-- BH-6893 (BH-6881.11): where bin/review-rescue.sh --dispatch runs its project
-- runs (bin/lib/lane-placement.sh). Seeded hub: the behaviour of today, one
-- process per project on the hub. No table is created here, so no index and no
-- retention rule apply. The flip to fly is a data change after a proof run, and
-- it waits for the alert path off the hub (#6889) and for a lane machine that
-- can do the rescue's git work (the repo clone): see
-- docs/notes/2026-10-15-BH-6893-review-rescue-per-project.md.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.review-rescue','hub','BH-6893: hub or fly; the review-rescue project runs. Seeded hub; fly waits for a proof run and #6889','seed','2026-10-15T19:43:00Z');

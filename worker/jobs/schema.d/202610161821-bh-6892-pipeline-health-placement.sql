-- BH-6892 (BH-6881.10): where bin/pipeline-health.sh --dispatch runs its
-- project runs (bin/lib/lane-placement.sh). Seeded hub: the behaviour of today,
-- one process per project on the hub. No table is created here, so no index and
-- no retention rule apply. The flip to fly is a data change after a proof run:
-- docs/notes/2026-10-16-BH-6892-pipeline-health-offhub.md has the procedure.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.pipeline-health','hub','BH-6892: hub or fly; the pipeline-health project runs. Seeded hub; fly is a data change after a proof run','seed','2026-10-16T12:38:00Z');

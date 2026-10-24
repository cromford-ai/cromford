-- BH-8119 (the rest of BH-8027): project-6-os lead reviews run on the Fly
-- pool. On 2026-10-22 box-project-6-os-1 reached load 60+ while it ran lead
-- reviews, and 6 green PRs waited 30-60 min for a verdict. the operator approved the
-- move (2026-10-22). The reader is lrp_placed (bin/lib/lead-pool.sh); it moves
-- a review only when the project routing is pool|0. KILL KNOB: set this row to
-- box. The next lead-review tick then runs on the project box, with no deploy.
-- INSERT OR IGNORE keeps an operator value. No table is created, so no index
-- and no retention rule apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.lead-review.project-6-os','fly','BH-8119: project-6-os lead reviews run on the Fly pool; set box to return them to the project box with no deploy','seed','2026-10-23T00:00:00Z');

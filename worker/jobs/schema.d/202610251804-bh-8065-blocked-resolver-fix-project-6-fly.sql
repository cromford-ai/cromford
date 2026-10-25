-- BH-8065 (slice 2 of BH-8027): project-6-os blocked-resolver fix rounds run
-- on the Fly pool. On box-project-6-os-1 the fix round died with rc 137
-- (SIGKILL); builds, rebases and lead reviews of project-6-os already run on the
-- pool. The reader is frp_placed (bin/lib/fix-round-pool.sh), called by
-- bin/fix-round-claim.sh on the project box; it moves a round only when the
-- project routing is pool|0. KILL KNOB: set this row to box. The next claimed
-- round then runs on the project box, with no deploy. INSERT OR IGNORE keeps an
-- operator value. No table is created, so no index and no retention rule apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.blocked-resolver-fix.project-6-os','fly','BH-8065: project-6-os fix rounds run on the Fly pool; set box to return them to the project box with no deploy','seed','2026-10-25T00:00:00Z');

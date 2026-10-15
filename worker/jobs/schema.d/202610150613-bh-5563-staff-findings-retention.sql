-- ── BH-5563 fix round (lead BLOCK, BH-6730 iron law) ─────────────────────────
-- staff_findings and staff_suppressions come from BH-5560
-- (0012-bh-5560-staff-findings.sql, on main), so this is a NEW fragment and
-- the merged one is not edited.
--
-- INDEX. The resolver's hourly work list in src/routes/staff-outcomes.js,
--   SELECT ... FROM staff_findings WHERE status='filed' AND ticket_url IS NOT
--   NULL AND id > ?1 ORDER BY id LIMIT ?2,
-- read every row after the cursor (rowid range) and filtered on status. Almost
-- every row is claimed or resolved, not filed. idx_staff_findings_status_id
-- serves it as one index range: status = 'filed', id > cursor, in id order.
--
-- RETENTION (BH-6750 job, src/routes/retention.js). Both tables grow:
--   staff_findings.done        a finished finding (digested, refused,
--                              unsupported, failed, merged, rejected or noise)
--                              whose updated_at is older than
--                              retention.staff_findings.done_days (365). The
--                              row is the claim dedup for its fingerprint: while
--                              it exists, the same source item is never claimed
--                              again. 365 d keeps that dedup for a year after
--                              the finding finished. Its children go in the same
--                              D1 batch, before it: the staff_outcomes row and
--                              the 'staff:<fp>' staff_decisions row. So no
--                              outcome or decision is ever left without its
--                              finding, and a re-claim after a year starts
--                              clean. A claimed or filed finding is live work
--                              and is never removed. (staff_outcomes.age can
--                              remove an outcome earlier and keep its finding;
--                              that finding is no longer filed, so nothing
--                              reads the missing outcome.)
--   staff_suppressions.revoked a revoked suppression created more than
--                              retention.staff_suppressions.revoked_days (180)
--                              ago. It mutes nothing.
--   staff_suppressions.expired an active suppression whose expires_at is more
--                              than retention.staff_suppressions.expired_days
--                              (180) in the past. It mutes nothing either.
--   A pending suppression (a noise proposal) is never removed.
--   retention.dry_run (seed 1) applies: the first runs only count.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE INDEX IF NOT EXISTS idx_staff_findings_status_id ON staff_findings(status, id);
CREATE INDEX IF NOT EXISTS idx_staff_findings_done ON staff_findings(updated_at)
  WHERE status IN ('digested','refused','unsupported','failed','merged','rejected','noise');
CREATE INDEX IF NOT EXISTS idx_staff_suppressions_status_created ON staff_suppressions(status, created_at);
CREATE INDEX IF NOT EXISTS idx_staff_suppressions_status_expires ON staff_suppressions(status, expires_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.staff_findings.done_days','365','BH-5563: days a finished staff finding (digested, refused, unsupported, failed, merged, rejected or noise) is kept after its last update (0 = off). The row is the claim dedup for its fingerprint; its outcome and decision rows go with it. Claimed and filed findings are never removed.','seed','2026-10-15T00:00:00Z'),
  ('retention.staff_suppressions.revoked_days','180','BH-5563: days a revoked staff suppression is kept after it was created (0 = off)','seed','2026-10-15T00:00:00Z'),
  ('retention.staff_suppressions.expired_days','180','BH-5563: days an active staff suppression is kept after it expired (0 = off). A pending one is never removed.','seed','2026-10-15T00:00:00Z');

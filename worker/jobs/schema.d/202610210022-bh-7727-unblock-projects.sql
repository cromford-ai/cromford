-- ── BH-7727 (UNB-5): the unblock lane's per-project opt-in ─────────────────
-- Read by bin/lib/unblock/scope.sh through the settings cache.
--   unblock.project.<p>.mode      off | shadow | act; a missing row is off
--   unblock.standing_approval.<p> 1 = standing approval for U4
-- Every fleet.conf project except cromford starts off. cromford has
-- no row here: UNB-0 seeds its shadow row, and an `off` row applied first
-- would make that INSERT OR IGNORE a no-op.
-- project-6-os has standing approval (the operator, 2026-10-20, comment 6294290733
-- item 4). Its mode stays off until an operator sets the row.
-- No table is created here. INSERT OR IGNORE: an operator's row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.project.project-1.mode','off','BH-7727: unblock lane mode for project-1: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-2.mode','off','BH-7727: unblock lane mode for project-2: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-3.mode','off','BH-7727: unblock lane mode for project-3: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-4.mode','off','BH-7727: unblock lane mode for project-4: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-5.mode','off','BH-7727: unblock lane mode for project-5: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-6.mode','off','BH-7727: unblock lane mode for project-6: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-8.mode','off','BH-7727: unblock lane mode for project-8: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-9.mode','off','BH-7727: unblock lane mode for project-9: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-7.mode','off','BH-7727: unblock lane mode for project-7: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.harness-console.mode','off','BH-7727: unblock lane mode for harness-console: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.cromford.mode','off','BH-7727: unblock lane mode for cromford: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.project-6-os.mode','off','BH-7727: unblock lane mode for project-6-os: off, shadow or act; missing = off','seed','2026-10-21T00:00:00Z'),
  ('unblock.standing_approval.project-6-os','1','BH-7727: standing approval for U4 on project-6-os (the operator 2026-10-20, comment 6294290733 item 4); 1 = approved','seed','2026-10-21T00:00:00Z');

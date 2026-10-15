-- BH-6786: the post-merge prod smoke probe (bin/deploy-verify.sh through
-- bin/lib/smoke-probe.sh) asks <prod><deploy.<project>.smoke_path>. No row
-- probes the bare prod URL. project-6-os `/` redirects to `/os`, which Clerk
-- protects; `/sign-in` answers 200 signed out. INSERT OR IGNORE, so a re-apply
-- or an operator's own row is left as it is.
-- Note: docs/notes/2026-10-15-BH-6786-smoke-headers.md.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('deploy.project-6-os.smoke_path','/sign-in','BH-6786: smoke probe path for project-6-os; / redirects to the Clerk-protected /os','seed','2026-10-15T00:00:00Z');

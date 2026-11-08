-- BH-9100: the brand law's two knobs. bin/lib/brand-ui-law.sh reads them
-- through setting_get, called from bin/agent-call.sh:
--   ui.brand_file       repo-relative path of the brand/UI rules file; a
--                       project row ui.brand_file.<project> wins over it
--   ui.brand_ui_globs   globs that make a review diff a UI change
-- The code fallbacks equal these values. Data only: no new table, so no index,
-- no RLS and no retention rule apply (D1 is SQLite). INSERT OR IGNORE keeps an
-- operator's value.
-- Rollback: delete the brand file from the repo (or point the row at a path
-- that does not exist); every stage then keeps the system append it had before
-- this change.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('ui.brand_file','docs/claude/brand-ui.md','BH-9100: repo-relative brand/UI rules file the brand law names; per project ui.brand_file.<project>','seed','2026-11-05T00:00:00Z'),
  ('ui.brand_ui_globs','src/app/** app/** pages/** components/** public/** *.css middleware.* next.config.* *.tsx *.jsx *.vue *.svelte *.scss *.sass *.less','BH-9100: globs that make a review diff a UI change (the review stages carry the brand law only then)','seed','2026-11-05T00:00:00Z');

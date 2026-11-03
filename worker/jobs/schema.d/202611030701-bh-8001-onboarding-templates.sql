-- ── BH-8001 (BH-7935.4): New repo from a template ─────────────────────────
-- onboarding.template.<key>: owner/repo of the template repo the New repo
-- panel makes a repo from. Read by bin/lib/hub-probes/repo-create.sh
-- (setting_get, before the GitHub generate call) and by GET
-- /api/onboarding/repo-create/templates in src/routes/onboarding-repo-create.js
-- (settingsRows, booleans only). A value that is not a bare owner/repo (the
-- empty seed) is "no row": that template is off and no repo can be made from
-- it. PUT /api/settings refuses an empty value, so an operator turns a
-- template off again with '-', which both readers also treat as off.
-- onboarding.create_poll_ms / onboarding.create_poll_max_s: read by
-- console-ui/src/screens/onboard/NewRepoPanel.js (code fallbacks 5000 and 900).
-- No table is created here (D1, not Supabase: no RLS applies). INSERT OR
-- IGNORE: an operator's row survives a re-apply. One seed per statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.template.nextjs','','BH-8001: owner/repo of the Next.js template repo for New repo; empty or - = template off','seed','2026-11-02T23:40:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.template.worker','','BH-8001: owner/repo of the Worker template repo for New repo; empty or - = template off','seed','2026-11-02T23:40:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.template.empty','','BH-8001: owner/repo of the Empty template repo for New repo; empty or - = template off','seed','2026-11-02T23:40:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.create_poll_ms','5000','BH-8001: the New repo panel polls a pending create every this many ms. Code fallback 5000','seed','2026-11-02T23:40:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.create_poll_max_s','900','BH-8001: the New repo panel stops polling a pending create after this many seconds and shows Check again. Code fallback 900','seed','2026-11-02T23:40:00Z');

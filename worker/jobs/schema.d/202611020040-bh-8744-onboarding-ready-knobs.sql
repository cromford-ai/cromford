-- ── BH-8744 (BH-7935.3): the Ready screen's probe bucket and stale window ───
-- Read by src/routes/onboarding-ready.js in its one D1 batch. A missing row or
-- a value outside its range falls back to the code default of the same value
-- (READY_BUCKET_DEFAULT 300, READY_STALE_DEFAULT 3600).
-- No table is created here (D1, not Supabase: no RLS applies). INSERT OR
-- IGNORE: an operator's row survives a re-apply. One seed per statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.ready_bucket_s','300','BH-8744: the Ready screen files at most one ready-facts hub probe per project per this many seconds (integer 60..3600). Code default 300','seed','2026-10-30T04:57:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.ready_stale_s','3600','BH-8744: a ready-facts pass older than this many seconds shows as stale on the Ready screen (integer 300..86400). Code default 3600','seed','2026-10-30T04:57:00Z');

-- ── BH-9406: the pre-PR rebase fails closed; its knobs are settings rows ──────
-- Read by the `rebase fetch (BH-9406)` and `rebase verify gate (BH-9406)` spans
-- in bin/lib/rb/pr.sh through setting_get. Each has a code fallback that names
-- its row here.
-- The rebase_verify knobs (key prefix rebase_verify, then a dot):
--   mode (and mode.<project>, read first):
--     block = the default. A fetch of origin/<base> that never lands ends the
--             build BUILD_DEFERRED (exit 3). A rebase CONFLICT or a red
--             typecheck gets fix rounds, then REVIEW_BLOCKED (exit 6). No PR.
--     note  = the rollback: the old fail-open fetch and the old PR note.
--     A row that cannot be read, or holds any other value, is block.
--   fetch_attempts  1..10, default 3.
--   fetch_sleep_s   0..120, default 10 (between attempts).
--   fix_rounds      0..3, default 1.
--   fix_timeout_s   60..7200, default 1800 (per fix round).
-- A value out of range or not a number is the default.
-- D1 is SQLite, not Supabase: RLS does not apply. No new table, so no new
-- index. INSERT OR IGNORE seeds only, so a re-apply keeps an operator's value.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('rebase_verify.mode','block','BH-9406: block = a failed pre-PR fetch defers the build and an unfixed rebase conflict or red typecheck blocks it, no PR; note = the old PR note. Unreadable = block. Per project: rebase_verify.mode.<project>','seed','2026-11-10T19:13:00Z'),
  ('rebase_verify.fetch_attempts','3','BH-9406: attempts at the pre-PR git fetch of origin/<base> before BUILD_DEFERRED (1..10)','seed','2026-11-10T19:13:00Z'),
  ('rebase_verify.fetch_sleep_s','10','BH-9406: seconds between pre-PR fetch attempts (0..120)','seed','2026-11-10T19:13:00Z'),
  ('rebase_verify.fix_rounds','1','BH-9406: fix rounds on the build box for a pre-PR rebase conflict or red typecheck before REVIEW_BLOCKED (0..3)','seed','2026-11-10T19:13:00Z'),
  ('rebase_verify.fix_timeout_s','1800','BH-9406: timeout in seconds of one pre-PR rebase fix round (60..7200)','seed','2026-11-10T19:13:00Z');

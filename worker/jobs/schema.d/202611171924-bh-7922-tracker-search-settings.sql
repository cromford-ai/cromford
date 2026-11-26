-- ── BH-7922: the row cap of tracker_search ───────────────────────────────────
-- Additive only: no table, no DROP, no UPDATE. INSERT OR IGNORE, so a re-apply
-- never resets a value an operator changed. One statement per seed
-- (bin/harness-sync.sh applies the file statement by statement, BH-1000).
-- Read by bin/lib/tracker.sh (_trk_search_max), once per process; its code
-- fallback is 50, the same as this seed (tests/tracker-create-search.bh-7922-test.sh K1-K4).
-- The key is trk_search.*, not tracker_*: the tracker_* range holds only the
-- per-project connection rows that /api/connections reads (BH-7924, W5/W8).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('trk_search.max_rows','50','BH-7922: the most rows tracker_search <query> answers (1..100), on every tracker; it is also the page size the adapter asks for (Jira maxResults, Linear first). A title-dedupe check needs only "is there one already". Read by bin/lib/tracker.sh _trk_search_max, code fallback 50','seed','2026-11-17T19:24:00Z');

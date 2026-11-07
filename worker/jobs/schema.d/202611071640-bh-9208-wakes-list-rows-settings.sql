-- ── BH-9208: the GET /api/wakes page size ──────────────────────────────────
-- Reader: worker/jobs/src/routes/wakes.js (GET /api/wakes, intSettingOr; code
-- fallbacks WAKES_LIST_DEFAULT_ROWS 200 and WAKES_LIST_MAX_ROWS 500).
-- No table is created here, so no index or RLS applies.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('wakes.list_default_rows','200','BH-9208: rows GET /api/wakes returns with no ?limit (whole number 1..1000, not above wakes.list_max_rows). Code default 200.','seed','2026-11-07T16:40:00Z'), ('wakes.list_max_rows','500','BH-9208: most rows one GET /api/wakes page returns (whole number 1..1000). bin/lib/pr-snapshot-wakes.sh and bin/pool-wake-poll.sh page at up to 500 and read a shorter page as the end, so keep this >= 500. Code default 500.','seed','2026-11-07T16:40:00Z');

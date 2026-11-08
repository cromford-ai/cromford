-- ── BH-9190: the D1 overload retry knobs ────────────────────────────────────
-- Reader: worker/jobs/src/lib/d1-retry.js (retryKnobs). It reads these rows
-- ONLY from the settings snapshot already in memory (lib/settings-cache.js
-- peekSetting), never by a D1 query. With no snapshot, or a value out of
-- range, the code constants D1_RETRY_ATTEMPTS (5) and D1_RETRY_BASE_MS (100)
-- apply; the seed values equal them, so a deploy changes nothing.
-- No table is created here, so no index or RLS applies.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('d1_retry.attempts','5','BH-9190: how many times the jobs worker sends a D1 call that D1 rejects as overloaded before it gives up (whole number 1..8; code default 5). Read from the in-memory settings snapshot only.','seed','2026-11-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('d1_retry.base_ms','100','BH-9190: the first backoff wait in ms before a retry of an overloaded D1 call; it doubles per attempt up to 1000 ms, with jitter (whole number 10..500; code default 100). Read from the in-memory settings snapshot only.','seed','2026-11-06T00:00:00Z');

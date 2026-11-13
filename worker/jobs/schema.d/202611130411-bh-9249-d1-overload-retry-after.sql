-- ── BH-9249: the retry hint on a D1 overload 503 ────────────────────────────
-- Reader: worker/jobs/src/lib/d1-overload-answer.js (retryAfterS). It reads
-- this row ONLY from the settings snapshot already in memory
-- (lib/settings-cache.js peekSetting), never by a D1 query, because it is read
-- when D1 is overloaded. With no snapshot, or a value that is not a whole
-- number 1..60, the code constant D1_OVERLOAD_RETRY_AFTER_S (2) applies; the
-- seed value equals it, so a deploy changes nothing.
-- No table is created here, so no index or RLS applies.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('d1_overload.retry_after_s','2','BH-9249: the retry-after header, in seconds, on the 503 the jobs worker answers when a D1 call gives up on an overload (whole number 1..60; code default 2). Read from the in-memory settings snapshot only.','seed','2026-11-08T00:00:00Z');

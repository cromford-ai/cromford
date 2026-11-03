-- ── BH-8848: vs_publish rate-limit retry cap ───────────────────────────────
-- bin/lib/verdict-status.sh waits a status POST's Retry-After once, when it is
-- 1..this many seconds and the 403/429 was a rate limit. 0 = never retry. Valid
-- 0..120 (catalog/lanes.d/_lib.verdict-status.json); a missing row is 30, the
-- code fallback in _vs_retry_max.
-- No table: a settings seed only. INSERT OR IGNORE, so a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lib.verdict-status.vs_retry_after_max_s','30','BH-8848: the longest Retry-After (seconds) vs_publish waits before one retry of a rate-limited status POST; 0 = never retry','seed','2026-11-02T00:00:00Z');

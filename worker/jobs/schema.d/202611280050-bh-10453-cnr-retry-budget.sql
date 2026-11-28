-- ── BH-10453 (BH-9555.3): the retry budget of bin/lib/cnr-retry.sh ──────────
-- lib.could-not-read.cnr_retry_budget_s: seconds cnr_retry may spend on one
-- read that could not read (401, 403, 429, 5xx, no answer), backoff 2, 4, 8 s.
-- Range 0..120; 0 = one read, as before. No row: env CNR_RETRY_BUDGET_S, then 20.
-- No table is created here, so no index or RLS applies.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lib.could-not-read.cnr_retry_budget_s','20','BH-10453: seconds bin/lib/cnr-retry.sh cnr_retry may spend on one could-not-read GitHub read (backoff 2, 4, 8 s); 0..120, 0 = one read','seed','2026-11-28T00:50:00Z');

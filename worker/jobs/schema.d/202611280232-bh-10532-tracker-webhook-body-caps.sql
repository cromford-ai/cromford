-- ── BH-10532: the Jira and Linear receivers' body caps ─────────────────────
-- No table is created here, so no index or RLS applies.
-- webhook.jira.max_body_bytes / webhook.linear.max_body_bytes: the request
--   body cap of POST /webhooks/jira and /webhooks/linear, checked after the
--   secret and signature-shape check and BEFORE the HMAC. Over it is 413 and
--   nothing is written. Reader: worker/jobs/src/lib/webhook-receiver.js
--   bodyCapOf(env, vendor) (the in-memory settings snapshot only, so an
--   unsigned caller causes no D1 read). A whole number in 1024..26214400;
--   anything else uses the code fallback WEBHOOK_MAX_BODY_BYTES (5242880), the
--   same fallback as webhook.github.max_body_bytes.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('webhook.jira.max_body_bytes','5242880','BH-10532: Jira webhook request body cap in bytes, checked before the HMAC; over it is 413 with no write. Reader: worker/jobs/src/lib/webhook-receiver.js bodyCapOf(env, "jira") (fallback 5242880; valid 1024..26214400).','seed','2026-11-28T02:32:00Z'),
  ('webhook.linear.max_body_bytes','5242880','BH-10532: Linear webhook request body cap in bytes, checked before the HMAC; over it is 413 with no write. Reader: worker/jobs/src/lib/webhook-receiver.js bodyCapOf(env, "linear") (fallback 5242880; valid 1024..26214400).','seed','2026-11-28T02:32:00Z');

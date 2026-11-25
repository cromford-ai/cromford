-- ── BH-9934 (BH-9926.2): the GitHub receiver's two knobs ───────────────────
-- No table is created here, so no index or RLS applies.
-- webhook.github.max_body_bytes: the request body cap, checked BEFORE the
--   HMAC. Over it is 413 and nothing is written. Reader:
--   worker/jobs/src/lib/webhook-receiver.js bodyCapOf (the in-memory settings
--   snapshot only, so an unsigned caller causes no D1 read). A whole number in
--   1024..26214400; anything else uses the code fallback WEBHOOK_MAX_BODY_BYTES
--   (5242880). GitHub caps a payload at 25 MB.
-- webhook.github.self_echo_actions: the space-separated <event>.<action> pairs
--   whose delivery writes no wake when a fleet App (HARNESS_SELF_APPS) sent it.
--   Reader: webhook-receiver.js receiverKnobs (fallback SELF_ECHO_ACTIONS, the
--   same four). "" turns the filter off.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('webhook.github.max_body_bytes','5242880','BH-9934: request body cap in bytes, checked before the HMAC; over it is 413 with no write. Reader: worker/jobs/src/lib/webhook-receiver.js bodyCapOf (fallback 5242880; valid 1024..26214400).','seed','2026-11-24T03:25:00Z'),
  ('webhook.github.self_echo_actions','pull_request.labeled pull_request.unlabeled issue_comment.created issue_comment.edited','BH-9934: <event>.<action> pairs that write no wake when a fleet App (HARNESS_SELF_APPS) sent them; the record still writes. Reader: worker/jobs/src/lib/webhook-receiver.js receiverKnobs (fallback the same four); "" = filter off.','seed','2026-11-24T03:25:00Z');

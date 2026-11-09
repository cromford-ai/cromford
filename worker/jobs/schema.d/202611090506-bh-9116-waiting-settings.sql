-- ── BH-9116: the "To do (waiting)" view knobs as settings rows ──────────────
-- Read by POST /api/waiting/state (src/routes/waiting.js) through the
-- per-isolate settings snapshot, row first, then the code fallback (the values
-- below). No table is created here, so no index or RLS applies; the route reads
-- existing tables on their primary keys and existing indexes only.
-- INSERT OR IGNORE: an operator's row survives a re-apply. One seed per
-- statement (bin/harness-sync.sh applies statement by statement, BH-1000).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('waiting.stale_claim_min','30','BH-9116: a claimed build_queue row older than this many minutes, with no live job, is a stale claim; a job heartbeat older than this is not live','seed','2026-11-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('waiting.max_tickets','2000','BH-9116: the most open tickets one POST /api/waiting/state reads; more are cut and the answer says truncated','seed','2026-11-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('waiting.defer_lookback_min','10080','BH-9116: how far back (minutes) a parked or budget_stopped job counts as the ticket''s last build answer','seed','2026-11-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('waiting.reason_text_max','200','BH-9116: the most characters of a queue or job reason text the waiting view returns and shows','seed','2026-11-05T00:00:00Z');

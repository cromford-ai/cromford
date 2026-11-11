-- ── BH-8973 (C0): the knobs of GET /api/ticket-status and /api/ticket-status/stuck ──
-- Settings rows only, no table. The routes (worker/jobs/src/routes/ticket-status.js)
-- read them through the per-isolate settings snapshot, so a row change needs no
-- deploy. Each value must be a whole number >= 1 (stuck_min >= 0); any other
-- value is the code default named in the note.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('ticket_status.stuck_min','90','BH-8973: GET /api/ticket-status/stuck reports an open queue row with no activity (state change, heartbeat, stage event, spawn or marker) for this many minutes (whole number >= 0; code default 90).','seed','2026-11-02T00:00:00Z'),
  ('ticket_status.batch_max','20','BH-8973: tickets one GET /api/ticket-status call may name; more is 400 too_many, never a silent cut (whole number >= 1; code default 20).','seed','2026-11-02T00:00:00Z'),
  ('ticket_status.attempts_limit','20','BH-8973: attempts and phase events returned per ticket, newest first; more sets truncated.attempts / truncated.events (whole number >= 1; code default 20).','seed','2026-11-02T00:00:00Z'),
  ('ticket_status.stuck_scan_limit','200','BH-8973: open queue rows one GET /api/ticket-status/stuck reads, oldest enqueued first; more sets truncated (whole number >= 1; code default 200).','seed','2026-11-02T00:00:00Z');

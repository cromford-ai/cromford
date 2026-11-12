-- BH-7597 (slice C0): the knobs of a saved browser session. No table: a
-- session is web_vault field session_state (202610200735-bh-7595-web-vault.sql),
-- written by POST /api/web-session/save and read by POST /api/web-session/load
-- (routes/web-session.js, client bin/lib/web-session.sh).
-- session_max_days: a session whose updated_at is at or before now - this many
-- days is refused `expired` and is not used.
-- session_max_bytes: the size cap of a saved session, read by the worker and
-- the client.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.web-task.session_max_days','14','BH-7597: days a saved web-task browser session (web_vault field session_state) is used after its last save (1..365); an older one is refused expired and the run signs in again; a missing or bad value uses the code default 14','seed','2026-11-01T00:00:00Z'),
  ('lane.web-task.session_max_bytes','262144','BH-7597: the size cap in bytes of a saved web-task browser session (1024..1048576), checked by POST /api/web-session/save and by wsess_save; a missing or bad value uses the code default 262144','seed','2026-11-01T00:00:00Z');

-- ── BH-7325: migration_reservations ─────────────────────────────────────────
-- One row per (project, ticket key): the migration number (the NNNN of a
-- <dir>/NNNN_<name>.sql file in that project's repo) a build reserved before it
-- wrote the file. The writer is bin/lib/migration-number.sh (mn_reserve, from
-- the plan stage and bin/migration-number.sh reserve) through
-- POST /api/migration-numbers/reserve; the readers are that route and the
-- retention rule. Note: docs/notes/2026-10-17-BH-7325-migration-numbers.md.
--
-- INDEXES. Each query and the index that serves it:
--   reserve, the top read  SELECT MAX(number) ... WHERE project = ?1
--         the primary key (project, number): one seek to the range end.
--   holder read            WHERE project = ?1 AND number = ?2
--         the primary key (project, number): one seek.
--   reserve, the upsert    ON CONFLICT(project, ticket_key) and the read back
--         WHERE project = ?1 AND ticket_key = ?2
--         idx_migration_reservations_ticket (project, ticket_key), unique.
--   retention id read      WHERE reserved_at < ?1 ORDER BY reserved_at
--         idx_migration_reservations_at (reserved_at).
--
-- RETENTION (src/routes/retention.js rule migration_reservations.age, the hourly
-- bin/d1-retention.sh lane). A row is a short claim: after
-- retention.migration_reservations.days (30) its number is on main, in a PR or
-- unused, so the row is deleted, not archived (no money, no history).
-- retention.dry_run applies as for every rule.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS migration_reservations (
  project TEXT NOT NULL,
  number INTEGER NOT NULL,
  ticket_key TEXT NOT NULL,
  floor INTEGER NOT NULL,
  reserved_at TEXT NOT NULL,
  PRIMARY KEY (project, number)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_migration_reservations_ticket ON migration_reservations(project, ticket_key);
CREATE INDEX IF NOT EXISTS idx_migration_reservations_at ON migration_reservations(reserved_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.migration_reservations.days','30','BH-7325: days a migration-number reservation row is kept (0 = off)','seed','2026-10-17T12:43:00Z'),
  ('migration_number.reserve','1','BH-7325: 0 turns off the plan-stage migration-number reservation and its prompt line (the review check stays on; its mode is the pr-self-check row)','seed','2026-10-17T12:43:00Z');

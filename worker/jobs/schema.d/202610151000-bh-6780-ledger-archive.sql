-- BH-6780 (BH-6863, slice C0): the ledger archive read. GET /api/ledger?kind&key
-- (worker/jobs/src/routes/ledger.js) reads env.ARCHIVE on a hot miss for a kind
-- listed in archive_kinds or archived_kinds (worker/jobs/src/lib/ledger-archive.js).
-- Both lists are empty here, so no kind reads the archive until an operator
-- lists one. archive_days is read by the ledgers.archive retention rule (a later
-- slice); 0 keeps it off. No table is created, so no index or retention rule.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.ledgers.archive_days','0','BH-6780: days after which the ledgers.archive rule moves an allowlisted kind''s rows to the archive store; 0 = off','seed','2026-10-15T00:00:00Z'),
  ('retention.ledgers.archive_kinds','','BH-6780: comma list of ledger kinds that may move to the archive store (max 64, each at most 32 chars); a GET miss on a listed kind reads the archive','seed','2026-10-15T00:00:00Z'),
  ('retention.ledgers.archived_kinds','','BH-6780: written by the ledgers.archive rule; never remove a kind by hand while its rows are in the archive','seed','2026-10-15T00:00:00Z');

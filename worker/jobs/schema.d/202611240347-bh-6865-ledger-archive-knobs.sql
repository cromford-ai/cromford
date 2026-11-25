-- BH-6865 (BH-6780.2): two knobs of the ledgers.archive retention rule
-- (worker/jobs/src/routes/retention.d/bh-6865-ledgers-archive.js).
-- retention.ledgers.sticky_wait_s: the rule records a kind in
-- retention.ledgers.archived_kinds, then waits this many seconds before it
-- moves the kind's first row, so every isolate's settings cache (60 s cap)
-- reads the kind as sticky first.
-- retention.ledgers.archive_min_days: the lowest retention.ledgers.archive_days
-- the rule accepts (code fallback and absolute floor 91,
-- lib/ledger-kind-class.js LEDGER_ARCHIVE_FLOOR_DAYS).
-- No table is created, so no index or retention rule.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.ledgers.sticky_wait_s','120','BH-6865: seconds the ledgers.archive rule waits after it records a kind in archived_kinds before it moves that kind; valid 120..86400 (2x the 60 s settings cache cap), else 120','seed','2026-11-02T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.ledgers.archive_min_days','91','BH-6865: lowest retention.ledgers.archive_days the ledgers.archive rule accepts; a smaller window is off; valid 91..3650; a value below 91 is ignored (the floor stays 91)','seed','2026-11-02T00:00:00Z');

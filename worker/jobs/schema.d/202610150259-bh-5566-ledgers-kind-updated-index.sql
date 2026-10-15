-- BH-5566 (BH-5556.9): the Dispatcher's post-deploy check reads
-- GET /api/ledger?kind=deploy&limit=N on every tick: WHERE kind=?
-- ORDER BY updated_at DESC, key DESC LIMIT N (src/routes/ledger.js).
-- idx_ledgers_kind serves the filter but sorts every deploy row in a temp
-- b-tree; this index serves the filter and the order (BH-6730 iron law,
-- EXPLAIN-tested in tests/staff-dispatcher.bh-5566-test.sh D13).
-- Retention: ledgers hold history and are never deleted
-- (202610142030-bh-6750-d1-retention.sql). Additive and re-runnable.
CREATE INDEX IF NOT EXISTS idx_ledgers_kind_updated ON ledgers(kind, updated_at, key);

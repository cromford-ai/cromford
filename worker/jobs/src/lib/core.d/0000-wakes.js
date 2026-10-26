// Frozen baseline: CREATED_TABLE_OVERRIDES.wakes, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-1267 — the doorbell table, entered here for its THIRD index rather than
  // for the table itself: `idx_wakes_at` is what makes the daily
  // POST /api/wakes/prune (`at < ?1 ORDER BY at ASC LIMIT ?2`) a covering index
  // search instead of a scan of a table that, until this ticket, nothing ever
  // deleted from. `bin/harness-sync.sh` applies
  // schema.sql statement by statement before the deploy and is what reaches the
  // live database first; this map is the BH-658 belt to that, and the only
  // thing that makes the index true on the first prune if a deploy ever runs
  // ahead of an apply. Column for column with schema.sql (the wakes-prune test
  // asserts the agreement), IF NOT EXISTS throughout, additive, never a DROP.
  wakes: [
    `CREATE TABLE IF NOT EXISTS wakes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       kind TEXT NOT NULL,
       key TEXT NOT NULL,
       event TEXT,
       minute TEXT NOT NULL,
       at TEXT NOT NULL,
       acked_at TEXT
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_wakes_dedupe ON wakes(repo, kind, key, minute)",
    "CREATE INDEX IF NOT EXISTS idx_wakes_unacked ON wakes(acked_at, id)",
    "CREATE INDEX IF NOT EXISTS idx_wakes_at ON wakes(at)",
    // BH-6727 (schema.d/202610141900): the cursor read WHERE id > ? AND repo = ?.
    "CREATE INDEX IF NOT EXISTS idx_wakes_repo_id ON wakes(repo, id)",
    // BH-6799 (schema.d/202610150809): the claim's lower(repo) and kind ranges.
    "CREATE INDEX IF NOT EXISTS idx_wakes_repo_lc_id ON wakes(lower(repo), id)",
    "CREATE INDEX IF NOT EXISTS idx_wakes_kind_id ON wakes(kind, id)",
  ],
};

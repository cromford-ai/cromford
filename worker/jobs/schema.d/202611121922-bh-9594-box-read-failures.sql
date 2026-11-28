-- ── BH-9594 (the BH-9555 contract): could-not-read records ──────────────────
-- A lane that reads GitHub and gets 401/403/429/5xx or no answer did not learn
-- a fact. bin/lib/could-not-read.sh cnr_record records that read against the
-- box through POST /api/box-read-failures (src/routes/box-read-failures.js):
-- one box_read_failures row per failure, and the box's running count in
-- box_cred_health. An `ok` read sets the count to 0 and adds no row. The one
-- writer in this slice is bin/orphan-reconcile.sh. Readers: GET
-- /api/box-read-failures (later the BH-9555 failover and fingerprint children).
-- Doc: docs/STATE-STORES.md (box_read_failures / box_cred_health).
--
-- INDEXES. Each read and the index that serves it:
--   recent failures of a box          WHERE box=? [AND cred_class=?]
--                                     ORDER BY at DESC LIMIT ?
--                                     idx_box_read_failures_box_cred_at
--   retention ids                     WHERE at < ? ORDER BY at LIMIT ?
--                                     idx_box_read_failures_at
--   health rows of a box              WHERE box=?  the primary key
--   the upsert of one counter         ON CONFLICT (box, cred_class)
--                                     the primary key
--
-- RETENTION (retention.d/bh-9594-box-read-failures.js, the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies): a box_read_failures
-- row older than retention.box_read_failures.days (14) is deleted. The rows
-- are diagnostic, not money or history. box_cred_health is bounded: at most
-- one row per box and credential class (boxes x 4).
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS box_read_failures (
  id INTEGER PRIMARY KEY,
  box TEXT NOT NULL,
  project TEXT NOT NULL,
  cred_class TEXT NOT NULL,
  status TEXT NOT NULL,
  reason TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_box_read_failures_box_cred_at ON box_read_failures (box, cred_class, at);
CREATE INDEX IF NOT EXISTS idx_box_read_failures_at ON box_read_failures (at);

-- no-index: box_cred_health the primary key (box, cred_class) serves every read; at most boxes x 4 rows
-- no-retention: box_cred_health one row per box and credential class (boxes x 4); the counter is overwritten in place
CREATE TABLE IF NOT EXISTS box_cred_health (
  box TEXT NOT NULL,
  cred_class TEXT NOT NULL,
  consecutive INTEGER NOT NULL DEFAULT 0,
  last_status TEXT,
  last_failure_at TEXT,
  last_ok_at TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (box, cred_class)
);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.box_read_failures.days','14','BH-9594: days a box_read_failures row is kept (retention.d/bh-9594-box-read-failures.js). Two weeks covers a failover investigation.','seed','2026-11-12T19:22:00Z'),
  ('lib.could-not-read.cnr_enforce','1','BH-9594: kill row of bin/lib/could-not-read.sh cnr_record (env CNR_ENFORCE). 0 = no could-not-read record is posted.','seed','2026-11-12T19:22:00Z'),
  ('box_read_failures.recent_max','20','BH-9594: the most recent failure rows GET /api/box-read-failures answers.','seed','2026-11-12T19:22:00Z');

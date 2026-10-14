
-- ── BH-5750: orgo_computers and orgo_account_reads (live Orgo state) ──
-- The local copy of each Orgo account's GET /computers list, written by the
-- hub lane bin/orgo-state.sh through PUT /api/orgo-computers and read by the
-- /machines ORGO STATE column (src/routes/orgo-computers.js). One row per Orgo
-- computer, keyed on orgo_id. raw_json is the entry as Orgo sent it, minus the
-- secret-looking keys the lane strips. A computer missing from a COMPLETE,
-- ok read gets gone_at (a tombstone); a row is never deleted, and a failed or
-- partial read tombstones nothing. A computer that reappears has gone_at
-- cleared. orgo_account_reads is the last read per account (the "as of"
-- state): ok 0 = the read failed, complete 0 = the list was partial or failed.
-- Only IF NOT EXISTS statements, so a re-apply through bin/harness-sync.sh is
-- a no-op. D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS orgo_computers (
  orgo_id TEXT PRIMARY KEY,
  name TEXT,
  account TEXT NOT NULL,
  status TEXT,
  cpu INTEGER,
  ram_gb INTEGER,
  disk_gb INTEGER,
  raw_json TEXT,
  seen_at TEXT NOT NULL,
  gone_at TEXT
);
CREATE INDEX IF NOT EXISTS orgo_computers_account ON orgo_computers(account, gone_at);
CREATE TABLE IF NOT EXISTS orgo_account_reads (
  account TEXT PRIMARY KEY,
  read_at TEXT NOT NULL,
  ok INTEGER NOT NULL CHECK (ok IN (0,1)),
  complete INTEGER NOT NULL CHECK (complete IN (0,1)),
  detail TEXT
);

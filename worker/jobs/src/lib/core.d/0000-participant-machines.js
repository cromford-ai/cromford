// Frozen baseline: CREATED_TABLE_OVERRIDES.participant_machines, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-5349 — the self-create copy of schema.sql's participant_machines block,
  // column for column (test/participants-schema.bh-5349.test.js pins the parity).
  participant_machines: [
    `CREATE TABLE IF NOT EXISTS participant_machines (
       id TEXT PRIMARY KEY,
       name TEXT NOT NULL UNIQUE,
       owner TEXT,
       requested_roles TEXT NOT NULL,
       granted_roles TEXT,
       token_sha256 TEXT NOT NULL UNIQUE,
       billing_account TEXT,
       status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','denied','revoked')),
       requested_at TEXT NOT NULL,
       decided_by TEXT,
       decided_at TEXT,
       revoked_by TEXT,
       revoked_at TEXT,
       last_seen_at TEXT,
       knobs TEXT
     )`,
    "CREATE INDEX IF NOT EXISTS idx_participant_machines_status ON participant_machines(status)",
  ],
};

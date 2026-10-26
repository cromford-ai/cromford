// Frozen baseline: CREATED_TABLE_OVERRIDES.triage_state, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // TRIAGE-STATE — the self-create copy of schema.sql's triage_state block,
  // column for column (test/triage-state.test.js pins the parity). A deploy that
  // ran before harness-sync applied the schema still answers the pre-check.
  triage_state: [
    `CREATE TABLE IF NOT EXISTS triage_state (
       project TEXT NOT NULL,
       ticket_key TEXT NOT NULL,
       ticket_label TEXT,
       input_hash TEXT,
       verdict TEXT,
       waiting_on TEXT,
       verdict_hash TEXT,
       triaged_at TEXT,
       next_recheck_at TEXT,
       reason TEXT,
       last_decision TEXT,
       last_decision_at TEXT,
       last_mode TEXT,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (project, ticket_key)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_triage_state_recheck ON triage_state(project, next_recheck_at)",
  ],
};

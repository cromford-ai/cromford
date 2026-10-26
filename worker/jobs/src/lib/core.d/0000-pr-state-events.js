// Frozen baseline: CREATED_TABLE_OVERRIDES.pr_state_events, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-1025.0 — the belt for the routes child (#1386): `ensureTable(env,
  // 'pr_state_events')` at the top of every handler; the view rides under
  // pr_state_events, because a view over a table the same call just created is
  // the only ordering that works on a database the deploy reached first.
  // Statement text is identical to worker/jobs/schema.sql's block, column for
  // column — worker/jobs/test/pr-state-schema.bh-1385.test.js compares the two
  // databases with PRAGMA table_info rather than trusting that sentence.
  pr_state_events: [
    `CREATE TABLE IF NOT EXISTS pr_state_events (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL, number INTEGER NOT NULL, state TEXT NOT NULL, since TEXT NOT NULL,
       head TEXT, reviewed TEXT, reason TEXT, url TEXT,
       alerted TEXT NOT NULL DEFAULT '-',
       at TEXT NOT NULL, actor TEXT
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_pr_state_events_dedupe ON pr_state_events(repo, number, state, since, alerted)",
    "CREATE INDEX IF NOT EXISTS idx_pr_state_events_pr ON pr_state_events(repo, number, id)",
    "CREATE INDEX IF NOT EXISTS idx_pr_state_events_state_at ON pr_state_events(state, at)",
    // BH-7764: the gateFacts range read (lib/pr-gate.js).
    "CREATE INDEX IF NOT EXISTS idx_pr_state_events_gate ON pr_state_events(repo, state, number, id)",
    "CREATE VIEW IF NOT EXISTS pr_state AS SELECT e.* FROM pr_state_events e WHERE e.id = (SELECT MAX(id) FROM pr_state_events WHERE repo=e.repo AND number=e.number)",
  ],
};

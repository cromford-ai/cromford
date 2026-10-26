// Frozen baseline: CREATED_TABLE_OVERRIDES.dequeue_events, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
// The nine dequeue-watch class words (BH-3727), as SQL, for the two CHECKs on
// dequeue_events below. 0000-dequeue-actions.js holds the same string for its
// CHECK; a fragment is a plain data module with no imports, so each keeps a copy.
const DQW_CLASS_SQL = "'rule-break','scanner-fp','semantic-test','textual-conflict','bystander','stale-status','flake','main-red','unclassified'";
export const CREATED_TABLE_OVERRIDES = {
  // BH-3727 (BH-3719.1) — the dequeue-watch ledger, the same DDL as the
  // BH-3719.1 block of schema.sql; worker/jobs/test/dequeue-watch.bh-3719.test.js
  // (SCH-PARITY) compares the two table shapes.
  dequeue_events: [
    `CREATE TABLE IF NOT EXISTS dequeue_events (
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head TEXT NOT NULL,
       run_id TEXT NOT NULL,
       project TEXT NOT NULL,
       dequeued_at TEXT,
       run_url TEXT,
       comment_id TEXT,
       batch_size INTEGER,
       members TEXT,
       draft INTEGER,
       attribution TEXT,
       attribution_how TEXT,
       class TEXT CHECK (class IS NULL OR class IN (${DQW_CLASS_SQL})),
       class_how TEXT,
       rule_id TEXT,
       suites TEXT,
       fail_lines TEXT,
       llm_fp TEXT,
       llm_attempted_at TEXT,
       llm_class TEXT CHECK (llm_class IS NULL OR llm_class IN (${DQW_CLASS_SQL})),
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (repo, pr, head, run_id))`,
    "CREATE INDEX IF NOT EXISTS idx_dequeue_events_llm_fp ON dequeue_events(llm_fp)",
    "CREATE INDEX IF NOT EXISTS idx_dequeue_events_created ON dequeue_events(created_at)",
  ],
};

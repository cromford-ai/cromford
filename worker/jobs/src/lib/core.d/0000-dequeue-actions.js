// Frozen baseline: CREATED_TABLE_OVERRIDES.dequeue_actions, moved byte for byte from core.js (BH-8448). A new statement is a new core.d/<ticket-key>-<name>.js.
// The nine dequeue-watch class words (BH-3727), as SQL, for the CHECK on
// dequeue_actions below. 0000-dequeue-events.js holds the same string for its
// two CHECKs; a fragment is a plain data module with no imports, so each keeps a copy.
const DQW_CLASS_SQL = "'rule-break','scanner-fp','semantic-test','textual-conflict','bystander','stale-status','flake','main-red','unclassified'";
export const CREATED_TABLE_OVERRIDES = {
  dequeue_actions: [
    `CREATE TABLE IF NOT EXISTS dequeue_actions (
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head TEXT NOT NULL,
       class TEXT NOT NULL CHECK (class IN (${DQW_CLASS_SQL})),
       action TEXT NOT NULL CHECK (action IN ('requeue','lead-request','fix-round','main-red-wait','hold','observe')),
       status TEXT NOT NULL DEFAULT 'claimed' CHECK (status IN ('claimed','done','failed','waiting')),
       project TEXT NOT NULL,
       ref TEXT,
       note TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (repo, pr, head, class))`,
    "CREATE INDEX IF NOT EXISTS idx_dequeue_actions_repo_pr_class ON dequeue_actions(repo, pr, class)",
    "CREATE INDEX IF NOT EXISTS idx_dequeue_actions_status_created ON dequeue_actions(status, created_at)",
  ],
};

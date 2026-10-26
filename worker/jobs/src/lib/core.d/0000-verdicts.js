// Frozen baseline: CREATED_TABLE_OVERRIDES.verdicts, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-1525 — same belt as model_routes above; worker/jobs/schema.sql's block
  // is the comment, this is the copy the routes run against. The two triggers
  // live ONLY here (schema.sql admits only table/index/view/insert-or-ignore,
  // tests/schema-additive.bh-1000-test.sh), and every verdicts route runs this
  // list before it reads or writes, so the table is append-only from its first
  // touch whether harness-sync or the route created it.
  verdicts: [
    `CREATE TABLE IF NOT EXISTS verdicts (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       verdict TEXT NOT NULL,
       source TEXT NOT NULL,
       reviewer_model TEXT,
       reviewer TEXT,
       report_url TEXT,
       note TEXT,
       created_at TEXT NOT NULL,
       auth TEXT,
       human_sig TEXT,
       review_tier TEXT,
       review_mode TEXT,
       break_it TEXT
     )`,
    "CREATE INDEX IF NOT EXISTS idx_verdicts_pr_head ON verdicts(repo, pr, head_sha, id)",
    // BH-5808: the lessons window reads (schema.d/202610161105-bh-5808-lessons.sql).
    "CREATE INDEX IF NOT EXISTS idx_verdicts_created ON verdicts(created_at)",
    "CREATE TRIGGER IF NOT EXISTS verdicts_no_update BEFORE UPDATE ON verdicts BEGIN SELECT RAISE(ABORT, 'verdicts is append-only'); END",
    "CREATE TRIGGER IF NOT EXISTS verdicts_no_delete BEFORE DELETE ON verdicts BEGIN SELECT RAISE(ABORT, 'verdicts is append-only'); END",
  ],
};

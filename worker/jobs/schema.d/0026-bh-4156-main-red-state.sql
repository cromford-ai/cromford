-- ── BH-4156: the main-red lanes' state as rows ──
-- bin/main-red-detector.sh, bin/main-red-pr-pair.sh and bin/main-red-recheck.sh
-- kept their records as files under state/main-red/ on the hub. These three
-- tables hold them now (src/routes/main-red-state.js). Every key is natural,
-- so a replayed write lands on the row it already wrote.
--
-- main_red_verdicts: what the detector's last tick decided for one repo
-- (red, green, held, none or infra). Upsert, the last tick wins.
-- no-index: main_red_verdicts one row per fleet repo; its one read is WHERE repo=?, served by the PRIMARY KEY (test/main-red-state-indexes.bh-4156.test.js)
CREATE TABLE IF NOT EXISTS main_red_verdicts (
  repo TEXT PRIMARY KEY,
  decision TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  sha TEXT NOT NULL DEFAULT '',
  at TEXT NOT NULL
);
-- main_red_pr_errors: what one open PR head failed on (job, first error, run
-- time), or '-' in all three for a head that finished green. A head sha is
-- immutable, so the row is written once (INSERT ... ON CONFLICT DO NOTHING).
-- The one rewrite is BH-5988's: a row whose error starts with '##[' came from
-- the old log parser, and one guarded UPDATE replaces it. Rows older than
-- MAIN_RED_PAIR_LEDGER_DAYS are pruned by the lane, as the files were.
CREATE TABLE IF NOT EXISTS main_red_pr_errors (
  repo TEXT NOT NULL,
  head TEXT NOT NULL,
  job TEXT NOT NULL,
  error TEXT NOT NULL,
  run_at TEXT NOT NULL,
  at TEXT NOT NULL,
  PRIMARY KEY (repo, head)
);
CREATE INDEX IF NOT EXISTS main_red_pr_errors_at ON main_red_pr_errors (repo, at);
-- main_red_pairs: one row per PR-pair alert episode (a job and first error
-- shared by two or more open PRs). Append-only: a resolve stamps resolved_at
-- and never deletes. The partial UNIQUE index allows one OPEN row per
-- (repo, hash), so two ticks cannot both open the same pair.
CREATE TABLE IF NOT EXISTS main_red_pairs (
  repo TEXT NOT NULL,
  hash TEXT NOT NULL,
  job TEXT NOT NULL,
  first_error TEXT NOT NULL DEFAULT '',
  prs TEXT NOT NULL DEFAULT '',
  opened_at TEXT NOT NULL,
  resolved_at TEXT,
  PRIMARY KEY (repo, hash, opened_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS main_red_pairs_open ON main_red_pairs (repo, hash) WHERE resolved_at IS NULL;

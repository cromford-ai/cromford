# merge-sweep enumerates builds of record from the ledger (BH-2312.1)

Doc: MERGE-CONDUCTOR

`bin/merge-sweep.sh` (BH-2348) is the first consumer of `bin/lib/builds-of-record.sh`. It sources
the lib right after `bin/jobs-client.sh`. A tree without the lib keeps the old walk.

- **Walk order.** `sweep_order` calls `bor_union` once per project in `$SWEEP_PROJECTS` (that is
  two feed calls per project). It orders each project's records by the ledger's `updated_at`, or
  the RESULT mtime for a record only this disk has. It keeps the BH-710 round-robin across
  projects. A line is `<project>\t<dir>\t<key>\t<ledger result line>\t<ledger updated_at>`.
- **Nothing local is dropped.** Every local `builds/*/RESULT` the ledger rows do not point at gets
  appended from `find` in its old bucket. That covers a dir that matches no project (`-`), a
  second `pool-` copy, and so on. So ledger mode never walks less than the file walk did. It also
  walks a `fly-` copy once, where the old walk also walked it once, in the `-` bucket.
- **Outage.** If any project's `bor_union` answers rc 1 (worker down, `JOBS_URL` unset, no
  client), the whole tick runs `sweep_order_files`. That is the old `find` walk, unchanged, so it
  produces the same order as before.
- **The ledger line wins over a stale local copy.** When the ledger has a row, `R` is its result
  line, not `head -1 RESULT`. The `PR_CREATED https://` filter applies to it the same way, so
  `RESULT_UNVERIFIED PR_CREATED …` and `PR_CREATE_FAILED …` never reach gh. The exception is a
  local RESULT whose mtime is newer than the row's `updated_at`. The row is put once, at build
  close, and two lanes rewrite line 1 of the local file after that without touching it:
  `bin/pr-url-reconcile.sh` relinks `PR_CREATE_FAILED` to `PR_CREATED … | RECONCILED` (BH-848, the
  sweep has to see it) and `bin/fly-pool.sh` relabels a dead `PR_CREATED` as `RESULT_UNVERIFIED`
  (the sweep must not merge it). In that case the newer local line is `R`.
- **A shifted ledger row is dropped.** Tab is IFS whitespace, so a blank feed field would move
  the result line into the timestamp column. A row whose `updated_at` column is not a date is
  skipped with `[merge-sweep] <p>: ledger row for <dir> has no updated_at in its column …`, and its
  local RESULT, if there is one, is walked from `find` like any dir the ledger does not name.
- **Ledger-only records are held.** A ledger row with no local dir (`bor_local_dir` rc 2) is never
  merged. Without the dir there is no review.md, no MIGRATION GATE grep and no REBASE note, and
  merging on `job_verdict` alone would be a new merge path. Each tick it logs
  `[merge-sweep] db-only record <key> <pr> held: no local evidence (review.md/migration-gate)`,
  increments `SWEEP_DB_ONLY` and moves on. It is not tallied, cached or marked done, so it merges
  normally once its record lands on this disk.
- **Tick summary.** The `tick TOTAL:` line ends with `db-only=<n>`. It prints when that count is
  above 0 too.
- **Truncation.** When a feed returns `BOR_LIMIT` rows, one line says
  `[merge-sweep] <p>: ledger feed hit BOR_LIMIT — the newest rows only; every local record is still walked`.

The lane has had no cron line since BH-1388. This changes the script, not its schedule.

Tests: `tests/merge-sweep-db-first.bh-2312-test.sh`.

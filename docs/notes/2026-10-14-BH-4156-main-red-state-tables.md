# The main-red lanes keep their records as rows (BH-4156, child C2)

Doc: DB-COORDINATION-SPEC, VERIFICATION-MAP

## The gap

`bin/main-red-detector.sh`, `bin/main-red-pr-pair.sh` and
`bin/main-red-recheck.sh` kept five records as files under `state/main-red/`
on the hub: the detector's `<owner>-<repo>.verdict`, the PR-pair head ledger
`pr-errors/<owner>-<repo>/<head>.tsv`, the pair marks
`pairs/<owner>-<repo>/<hash>`, the published marker `<flag>.published` and the
recheck stamp `recheck.last`. A fresh hub lost all five.

## What changed

- New schema fragment `worker/jobs/schema.d/0026-bh-4156-main-red-state.sql`
  (additive, `CREATE TABLE IF NOT EXISTS`, no DROP). `ensureTable` creates the
  tables on first use, and `bin/harness-sync.sh` applies the fragment before a
  deploy.
  - `main_red_verdicts(repo PK, decision, reason, sha, at)`: upsert, the last
    tick wins.
  - `main_red_pr_errors(repo, head, job, error, run_at, at, PK(repo, head))`:
    `INSERT ... ON CONFLICT DO NOTHING`. A stored error that starts with `##[`
    (the BH-5988 old-parser row) is replaced by one guarded UPDATE.
  - `main_red_pairs(repo, hash, job, first_error, prs, opened_at, resolved_at,
    PK(repo, hash, opened_at))`: append-only. A partial UNIQUE index on
    `(repo, hash) WHERE resolved_at IS NULL` allows one open row per pair. A
    resolve stamps `resolved_at` and never deletes.
- `.published` and `recheck.last` are `ledgers` rows: kind
  `main_red_published` (key = the flag name, status `on` or `off`) and kind
  `main_red_recheck` (key `last`, status = the epoch). They use the existing
  `job_ledger_get` / `job_ledger_put`.
- New route family `worker/jobs/src/routes/main-red-state.js`, registered by
  the numbered fragment `worker/jobs/test/route-table.d/774-main-red-state.txt`
  (BH-5788), in the bearer-gated table:
  `GET/PUT /api/main-red-state/verdict`, `GET/PUT /api/main-red-state/pr-errors`
  (`?heads=` up to 100), `POST /api/main-red-state/pr-errors/prune`,
  `GET/POST /api/main-red-state/pairs`, `POST /api/main-red-state/pairs/resolve`.
  Bad input is a 400, never cut to fit. No row is a 200 with `null` or `[]`. A
  D1 error is a 500 that names the table, never an empty 200.
- New client lib `bin/lib/main-red-state.sh` (`mrs_*` verbs over `_jobs_req`).
  Every verb answers rc 0 (done), 3 (read: no row), 2 (use today's file) or 1
  (could not read or write).
- The three lanes read and write the rows. The file is used only on rc 2:
  - `mrs_on` is rc 1 (no `_jobs_req`, an empty `JOBS_URL` or no
    `HARNESS_SECRET`), the same "no coordination DB here" fallback that
    `bin/jobs-client.sh` already has (BH-1957);
  - the worker answers 404 for the new routes, which is a box synced before
    the worker deploy. Then the lanes keep today's files until the deploy.
  A landed row write removes the leftover file. A leftover pair marker is
  opened as its row once, then removed.
- An unreadable row (rc 1) does not act:
  - pr-pair: an unreadable verdict raises no freeze (the pair still alerts);
    an unreadable head ledger or open-pair list gives no signal this tick.
  - detector: an unreadable published marker does no OFF republish this tick.
    One log line says so.
  - recheck: an unreadable stamp starts no detector this tick. One line in
    `logs/main-red.log` says so.
  - A verdict row that cannot be written writes no file. A reader does not act
    on an unreadable row, so a file would be read by nobody.
  - A published marker that cannot be written falls back to the file. A marker
    left on costs one harmless OFF republish later.

## Choices against the plan

- The route fragments are numbered: `773-conductor-state.txt` and
  `774-main-red-state.txt`, not `236-main-red-state.txt`. They were first
  key-named (`bh-4156-*.txt`), but a key-named fragment sorts after the
  `zz-*` sentinels of `tests/route-keyed-merge.bh-5788-test.sh` M1, which
  broke merge-queue batch #6830. BH-6750 moved its fragment to `772-retention`
  for the same reason. The 999 probe of `route-registry.bh-4607.test.js` N8
  stays the last family, unchanged.
- `main_red_pr_errors` has `job` and `run_at` beside `error`, and
  `main_red_pairs` has `job`, `first_error` and `prs`. The grouping reads the
  whole head row, and the resolve sweep reads the job and the PR list.
- `bin/main-red-bisect.sh` is not changed. It does not read `<slug>.verdict`
  on main 908ec1f7; its own state is `state/main-red-bisect/` (out of scope).
- The rows of `main_red_pr_errors` are pruned by age through
  `POST /api/main-red-state/pr-errors/prune` with `MAIN_RED_PAIR_LEDGER_DAYS`,
  as the file ledger was.
- A pair resolved and opened again in the same second collides on its primary
  key and is not opened. The lane runs every 10 minutes, so a resolve and a
  re-open are on different ticks.

## Verify

- `HARNESS_TEST_SANDBOX=1 bash tests/main-red-state-rows.bh-4156-test.sh`
  runs the lanes against the real worker over node:sqlite.
- `cd worker/jobs && node --test test/main-red-state.bh-4156.test.js`.
- After the worker deploy, on the hub:
  `curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/main-red-state/verdict?repo=example-org/cromford"`
  answers 200 with a `verdict` key. After one detector tick and one pr-pair
  tick, `find state/main-red -type f -not -path '*/body/*'` lists no file.

# A stopped pool machine's result comes from a row, and the pause names its source (BH-2643)

Doc: FLY-POOL-RESPAWN-CAP, DB-COORDINATION-SPEC

## What happened

On 2026-09-26 between 01:18Z and 01:45Z the pool reap logged 33 machines as
`dead (state=stopped)` and parked 14 tickets as "died 2 times". None of them
died. Each one was a reused machine that answered
`BUILD_DEFERRED REFUSED pause`, reported `job done`, idled 600 s and
autostopped with exit 0. The reap reads the result over ssh from
`/run/harness/RESULT`, which is tmpfs. A stopped machine can't be reached, so
`RES` came back empty and the liveness path counted a death.

## What changed

- **The machine writes its result to a row.** `run_job` in
  `fly/builder-runner.sh` calls `pool_result_row_write` after every job. On a
  pool machine (`POOL_MODE=1`) with a non-`RB-` key, it upserts a `ledgers` row
  with kind `pool-result`, key `<project>/<KEY>` and detail
  `{"rline":<RESULT line 1>,"machine":<FLY_MACHINE_ID>,"at":<epoch>}`. There is
  one row per key, not one per machine. If the write fails, the runner logs one
  line and the job's rc does not change.
- **The reap reads the row before it declares a death.** This only happens for
  a machine that is not started (`""|stopped|destroyed|failed|suspended`) and
  whose ssh read returned nothing. The row only counts when `machine` is the
  machine being reaped, `at` is no older than its `spawned_at` minus
  `POOL_RESULT_ROW_SKEW_S` (default 60), and `rline` passes
  `bin/result-prefix-ok.sh`.
  - A `BUILD_DEFERRED` row goes through the existing deferral arm. It is logged
    `DEFERRED`, `deferrals` goes up by one, `deaths` stays the same, the
    `REFUSED` spawn is un-recorded, and the machine is destroyed. The build dir
    gets `result-source` = `pool-result row`.
  - Any other row, such as `PR_CREATED`, is requeued with `deaths` unchanged
    and logged `stopped (state=…) after job done … not a death`. Its artifacts
    died with the machine, so the retry adopts the open PR.
  - No usable row, or an unreadable ledger, gives exactly the old dead path. An
    unreadable ledger also adds one `pool-result row … unreadable` line.
- **The pause refusal names the row.** `checkPause` now says
  `paused: pause_flags row <name> is active (updated <updated_at>)`. The builder's
  only pause check is this claim, and it reads only the row. The old
  `flags/<name>` text named a box file the builder never reads.
- **`jobs-client.sh flag-active` says which source answered.** It prints one
  stderr line: the row, the `flags/` file when the file is newer than an
  inactive row ("builders … are NOT paused"), or the file alone when the row
  could not be read or does not exist. `flag-set` says on stderr when it
  changed the file but the row PUT failed. stdout and rc are unchanged, and
  `bin/lib/jobs/flags.sh` (BH-1370 last-writer-wins) is untouched.

## Rollout

- `worker/jobs` has to be deployed (`bin/harness-sync.sh`) before the new
  reason text appears.
- The row writer runs on a machine once the harness tree is synced there.
  Until then no row exists, and the reap behaves as it did before.

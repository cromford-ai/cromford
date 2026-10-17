# The ci-read actions/runs read has a time bound (BH-6346)

Doc: MERGE-CONDUCTOR

## The gap

Sentry issue CROMFORD-HARNESS-K (project-3, head `856c198d`) is a worker killed
in step `ci-read`. The ci-read step reads CI through `mc_ci_state`
(`bin/lib/mc/classify.sh`), which calls
`gh_rest GET repos/<slug>/actions/runs?head_sha=<sha>`. BH-6810 gave `gh_rest`
an opt-in bound (`GH_REST_TIMEOUT_S`), but only `head_lag_tip` set it. A
stalled `gh api` connection held the ci-read step until `MC_STEP_TIMEOUT_S`
or the worker deadline killed the worker.

## What changed

- `mc_ci_read_timeout_s` (new, `bin/lib/mc/classify.sh`) reads
  `MC_CI_READ_TIMEOUT_S`: default 30 s, 0 = off, not a number = 30.
- `mc_ci_state` and `mc_ci_flake_runs` set `GH_REST_TIMEOUT_S` (local) from it,
  so both actions/runs reads are bounded. A cut read is `unavailable` in
  `mc_ci_state` and "no flake evidence" in `mc_ci_flake_runs`, as any failed
  read already was. Every caller of `mc_ci_state` gets the bound
  (`bin/blocked-resolver.sh`, `bin/lib/mq-premerge.sh`,
  `bin/lib/pr-owner/enroll.sh` read `unavailable` fail-closed).
- `mc_ci_state` sets the global `MC_CI_READ_WHY` to
  `HTTP <status>[ <reason>]` when the read fails, `parse` when the body does
  not parse, and to empty otherwise.
- `pr_worker` (`bin/merge-conductor.sh`) calls `mc_ci_state` as a plain command
  into `$MC_TICK_DIR/ci-state.<pid>` (removed after the read), so the global
  reaches the worker. A worker killed during the read leaves that file; the
  tick-dir sweep in `bin/lib/mc/locks.sh` deletes files older than one day. When the read was cut (reason `timeout`), it writes one
  line per (PR, head):
  `<key> CI_READ_HELD reason=read-timeout on <head8> (bound <n>s): the
  actions/runs read passed its bound; the row stays WAIT_CI this tick, no
  alert, the next tick reads again`. Attempts line: `cireadheld <key> <head>`.
  No STEP_TIMEOUT, no alert, no Sentry event, no memo write.
- `mc_ci_state` sets the global `MC_CI_READ_HELD=1` when the read was cut
  (WHY ends in ` timeout`), else 0; it reaches the worker (every tick, not only
  the tick that logs the line). `mc_classify` has an `unavailable` arm that
  answers `WAIT_CI checks unread — ...` when that flag is 1, so an approved
  CLEAN PR is never READY or enqueued on CI nobody read. Any other
  `unavailable` read (a 500, a 429, a parse failure) keeps its old path.
- A 401 still stops the worker with `AUTH_401`. A 429, a 500 or a 404 is
  `unavailable` with no CI_READ_HELD line.
- `ci-read` is not on the BH-6670 hold list: the step also sends reruns.

## Knob

- `MC_CI_READ_TIMEOUT_S` (default 30 s, 0 = off, not a number = 30).
  Fragment: `catalog/lanes.d/merge-conductor.knobs.d/MC_CI_READ_TIMEOUT_S.json`.
  Settings row: `lane.merge-conductor.mc_ci_read_timeout_s`.

No new env var must be set.

## Probe after deploy

    grep -E 'CI_READ_HELD' /root/harness/logs/merge-conductor.log | tail -5

Sentry issue CROMFORD-HARNESS-K must show 0 new `ci-read` events from a box at the merge sha.

Suite: `tests/mc-ci-read-bound.bh-6346-test.sh`.

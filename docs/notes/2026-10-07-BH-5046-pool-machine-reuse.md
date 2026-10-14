# Pool machine reuse (BH-5025: slices BH-5025.0, .1, .2)

Doc: BUILD-CONCURRENCY

A pool machine that is reused for a second job inherits what the first job
left behind: the env file it booted with, and any process still running. Four
changes make the second job behave like a first one.

- GH_TOKEN in the machine's `global.env` is synced from the rotated `gh-token`
  file, by `gh_token_live_sync_env` in `bin/lib/gh-token-live.sh`. It runs at
  `load_env` in `fly/builder-runner.sh` and after each rotation push in
  `bin/fly-pool.sh` (#5045, which this slice stacks on; not merged when this
  note was written).
- The build-slot gate is skipped on pool machines (#5046, this slice).
  `fly/entrypoint.sh` writes `flags/build-slots`=1 on every machine, so a
  process left over from the last job could hold `locks/build-slot-1.lock` and
  defer the next one with `BUILD_DEFERRED all 1 slots busy`. When `POOL_MODE=1`
  and `BUILDER_EXEC=1` are both set, the `# >>> build slots` block of
  `bin/lib/rb/gates.sh` logs `build slots: pool machine (POOL_MODE=1), one
  machine runs one job, slot gate skipped (BUILD_SLOTS=N not applied)` to the
  build's `pipeline.log` and takes no slot. Watcher boxes and dedicated
  builders keep the gate. Pinned by `tests/pool-slot-gate.bh-5025-test.sh`.
- A trigger-actor 401 is logged `token-401` and not counted as a lane failure
  (lands with #5047, not merged when this note was written).
- A hotfix that deferred on a reused machine is spawned fresh on a new machine,
  behind `lane.fly-pool.pool_hotfix_fresh_after_defer` (default 1) (lands with
  #5047, not merged when this note was written).

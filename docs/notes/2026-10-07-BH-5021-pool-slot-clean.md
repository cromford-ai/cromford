# A reused pool machine never hands a held build slot to the next build (BH-5021)

Doc: BUILD-CONCURRENCY, FLY-BUILDER-TRIAL

## What changed

- New `bin/pool-slot-clean.sh`, run on a pool machine. It probes every
  `locks/build-slot-*.lock` with `flock -n`, finds the processes holding a held
  one through their `/proc/<pid>/fd` links, logs each one (pid, ppid, age,
  argv with `*TOKEN*`/`*SECRET*`/`*KEY*`/`*PASSWORD*` values redacted) to
  stderr and `logs/pool-slot-clean.log`, and kills its process tree, children
  first: TERM, `POOL_SLOT_CLEAN_GRACE_S` (default 5) seconds, then KILL. It
  never signals itself, PID 1 or one of its own ancestors, and never deletes a
  lock file. One stdout line: `SLOTCLEAN ok clean`, `SLOTCLEAN ok cleaned=<n>
  pids=<list>` (exit 0), `SLOTCLEAN held lock=<name> pids=<list>` (exit 1), or
  `SLOTCLEAN unreadable <why>` (exit 2).
- Hub, `bin/fly-pool.sh` `next_job_or_destroy`: the reuse cleanup `mexec` now
  runs the cleaner too. `held` destroys the machine instead of reusing it and
  hands the claimed queue row back, on the same path as a failed cleanup.
  `cleaned=` reuses and says what it killed. An empty answer, or `SLOTCLEAN
  absent` from a machine whose tree predates the script, reuses as before.
  A machine whose reaped RESULT says `slot held on this machine` is never
  reused.
- Hub, the reap's deferral arm: a `BUILD_DEFERRED … slot held on this machine`
  RESULT leaves the ticket's deferral count and per-key spawn cap alone (the
  machine was at fault, not the ticket) and sets no project spawn hold. The
  plain box wording `BUILD_DEFERRED all N slots busy` still counts.
- Runner, `fly/builder-runner.sh`: `slot_preflight` runs the cleaner before
  `warm_up`. Still held, a plain build answers `BUILD_DEFERRED all 1 slots busy
  — slot held on this machine by <pids> after cleanup` in seconds, with no
  warm-up, no `gh` read and no run-build. A hotfix goes on.
- `bin/lib/rb/gates.sh` `# >>> build slots`: when every regular slot is held,
  `HOTFIX=1` tries exactly one more, `build-slot-<SLOTS+1>`, shared by all
  hotfixes, and logs `hotfix: all N slots busy, taking extra slot M for <KEY>`
  to `pipeline.log`. If that one is held too it defers with `… and the hotfix
  slot is held`. A plain build never tries it. Under `BUILDER_EXEC=1` the
  refusal carries ` — slot held on this machine`. `BUILD_SLOTS=0` (the box
  default) is unchanged: no slot lock at all.
- `bin/lib/trigger-actor.sh` `ta_gh_trigger`: an events page answering rc 75
  with `GH_REST_REASON` empty, `network`, `empty` or `cache-miss` is read again
  up to `PROJECT_2_EVENTS_RETRIES` (default 2) more times, sleeping
  `PROJECT_2_EVENTS_RETRY_BACKOFF_S` (default `"3 10"`) between tries. `rate-limit`
  and `quota-reserve` are not retried. A deferral after retries says
  `(after N retries)`; a read that needed one says so on the `TRIGGER-ACTOR
  allow` line.

## What it does not change

The Fly cost of a refused build is mostly reap latency: the cost row runs from
the handoff to the reap tick (`*/10`), so an early refusal still bills about one
tick. What this removes is the dirty machine being handed job after job.

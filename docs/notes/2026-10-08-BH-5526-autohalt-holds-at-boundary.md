# BH-5526: the cost autohalt holds new builds only, never in-flight work (slice C1)

Doc: COST, RUN-BUILD-GRAPH

**Why.** The cost autohalt wrote `flags/paused-<p>`, the human "pause this
project" flag. Five lanes read that flag and stop work that already started:

- `bin/merge-queue.sh` stood down, so an approved PR did not land.
- `bin/review-prs.sh` left an APPROVE unmerged.
- `bin/lib/rb/pr.sh` demoted a running build's tier-1 merge to tier 2.
- `bin/migration-autopilot.sh` did not apply a merged migration.
- `bin/run-triage.sh` exited, so its results sweep did not close out a finished
  build.

So one trip left tickets built but not merged, merged but not migrated, or
finished but not closed out.

**What changed.**

- The breaker writes its own flag, `spend-hold-<p>`. `cb_halt` in the
  `# >>> cost budget` block of `bin/pipeline-health.sh` (the $/PR rate breaker
  and the zero-merge breaker) writes it through `flag_set`. `bin/cost-local-brake.sh`
  writes it on the owning box during a worker outage. Neither writes
  `paused-<p>` now.
- The build launch gate (`# >>> budget launch gate`, `bin/lib/rb/gates.sh`) is
  the only reader. A fresh build of a held project writes
  `RESULT BUILD_DEFERRED spend-hold <p> — …`, one `pipeline.log` line with the
  hold reason, and one alert per (project, UTC day)
  (`flags/alerted-spend-hold-launch-<p>-<YYYYMMDD>`). It writes no `ADMITTED`
  and exits 3. The gate reads the row through `flag_active` and the file either
  way, so a worker outage answers from the file.
- A resume of an admitted build dir skips the gate (the C0 rule), so a hold set
  after a ticket started never stops that ticket.
- `pool_lane_failure` in `bin/fly-pool.sh` reads ` spend-hold ` as the lane's
  condition. A held project's pool job is not counted against the ticket.
- The breaker writes no hold when the project is already paused by a human, is
  already held, is inside the re-arm window (`state/costhalt/<p>`), or when the
  kill switch `cost-autohalt-off` is on.
- The pages (`costhalt:<p>`, `costzeromerge:<p>`, `costlocalhalt:<p>`) say
  "NEW BUILDS HELD at ticket start" and name the lift command.
- The console COST BREAKER card lists `spend-hold-<p>` rows as KIND `HOLD`. An
  older `paused-<p>` row with a breaker reason is still listed, as `PAUSE`.

**How to lift a hold.** `bin/jobs-client.sh flag_set spend-hold-<p> off`. The
console's resume (`resume_board`) clears `paused-<p>` only and does not lift a
hold. Deleting the file alone does not lift it: `flag_sync` re-creates the file
from the row.

**What did not change.**

- `paused-<p>` keeps its full meaning. Every lane that read it still reads it.
- The thresholds, the kill switches (`cost-autohalt-off`, `COST_AUTOHALT=0`),
  the re-arm stamp and `cost.autohalt.effective` are the same.
- `budget-stop-off` turns off the day-cap checks only. It does not lift a hold.
- A hold has no automatic expiry, the same as the old pause.
- Triage, fastpath and auto-enqueue do not read the hold. They launch, and the
  launch gate defers the build before any model call.

Tests: `tests/autohalt-boundary.bh-5526-test.sh`,
`console-ui/tests/cost-breaker.bh-5526.test.js`.

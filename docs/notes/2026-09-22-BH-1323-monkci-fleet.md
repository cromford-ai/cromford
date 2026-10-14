# BH-1323: CI moved to MonkCI; CI_RUNNER now refuses an unknown fleet

**What happened.** On 2026-09-22 ~04:47Z `CI_RUNNER` was flipped from the Fly
pool's labels (`["self-hosted","linux","bh-ci"]`) to `"monkci-ubuntu-24.04-4"` —
MonkCI hosted runners, one 4 vCPU VM per job. An A/B on the same tree
(`c8b3bb64`, the full 592-suite run) put the whole run at **17.5 min wall on
MonkCI against 23.7 min on the pool**, with job-minutes halving from 157 to 80
and the two shards that had been lost to 120 s per-suite kills passing. The cause
is contention rather than the image: the pool runs 8–12 runner slots per 16-vCPU
machine, so shards compete for CPU exactly when the drain is busiest.

**What changed in the repo.** `bin/ci-runner-known.sh` is new: it takes the raw
JSON text of `CI_RUNNER` and exits 0 only when it is byte-identical to one of the
two known fleets, 1 for anything else including the empty string, 2 on misuse.
The `lint` job of `.github/workflows/harness-ci.yml` runs it against the live
variable through `env: CI_RUNNER_VALUE: ${{ vars.CI_RUNNER }}` as its first step
after checkout. `docs/CI-RUNNERS.md` now names MonkCI as the current fleet (label,
sizes, the A/B table, the cost, how to re-run the A/B on one sha through
`workflow_dispatch` and the jobs API), carries a `## Known fleets` table the new
suite cross-checks against the script, demotes the Fly pool to the fallback, and
documents the pool's warm-minimum shrink and scale-up commands.
`"ubuntu-16-core"` is no longer a rollback target anywhere: it is not a known
fleet, so the guard refuses it, and the three places that named it (twice in the
doc, once in the `ci-runners-empty` alert body) now name MonkCI.

**The pool-empty page had to move with the guard.** `cmd_ci_runners` in
`bin/testhost-tick.sh` pages critical when the Fly pool reads empty past its
hold, and its body ended with "flip the `CI_RUNNER` repo variable back to
`"ubuntu-16-core"`" plus a flat claim that harness CI jobs queue and the drain
has stopped. After this ticket both sentences were wrong in the state the page
usually renders in: the guard refuses that value, so an operator who followed
the page turned the next run red, and with the gate on MonkCI an empty Fly pool
is the fallback fleet being down rather than a stopped drain. The body now
states the queue-and-stall consequence as conditional on what `CI_RUNNER` names,
names MonkCI as the current fleet, and points a pool that is cold on purpose (see
§ Warm minimum) at the knob that silences it, `bin/harness-ctl.sh set
testhost-tick CI_RUNNERS_ALERT_HOLD_MIN 0`. Nothing else in the lane moved:
severity is still `critical`, the id still `ci-runners-empty`, the hold and the
send-then-stamp ordering are untouched, and
`tests/ci-runners-alert.bh-1210-test.sh` stays green on all 49 assertions.
`tests/ci-runners-alert.bh-1323-test.sh` drives the real `tick` in a scratch
`$HARNESS` and asserts on the emitted alert argv, including running the real
`bin/ci-runner-known.sh` over every value the page recommends, so the page and
the guard cannot drift apart without a red suite.

**Why a script and a workflow step rather than an assertion in a suite.** The
ticket asked for the check in `tests/harness-ci-runners.bh-1206-test.sh`. The
value it has to read only exists in GitHub's API: a suite here runs with no
network, never sees `vars.CI_RUNNER`, and under BH-1203 test selection may not
run at all on a given PR. So the shape is the one BH-1206 already used for the
tool guards — a script that holds the list, plus a workflow step that hands it the
live value — and the new per-ticket suite
`tests/harness-ci-runners.bh-1323-test.sh` drives the script and pins the wiring.
A typo'd or deleted variable puts every job including `lint` on the hosted
fallback, which is exactly where the step then goes red.

**What did not change.** The fallback expression on every `runs-on` line is
untouched: this makes it loud, it does not remove it, and removing it would break
every fork and fresh clone. `.github/workflows/publish-share.yml` still
hard-codes `runs-on: ubuntu-latest` — it does not run the corpus, so it is not
part of the gate (ask 4); the new suite pins that non-change so a sweep cannot
fold it in. `tests/harness-ci-runners.bh-1206-test.sh` keeps all 39 of its
assertions unchanged — the check this ticket adds went into its own file rather
than into that one. The single edit there is its header comment, which said
"Today the variable holds the Fly pool's labels": that was true when BH-1206
wrote it and is false as of this diff, and leaving a stale current-state claim in
the file the ticket pointed at would have been the losing half of the same
contradiction T6 fixes in the alert.
`docs/notes/INDEX.md` is rendered by a docs pass, not by this PR.

**Still owed, and not done here.** The Fly `bh-ci-runners-example-org` pool (org
`board-builders`) is still sized for the whole corpus and billed idle. Shrinking
it to two warm machines needs the org token, which is the operator's; there is no
`flyctl` and no Fly credential on a watcher box, so ask 2 ships as the documented
commands in `docs/CI-RUNNERS.md` § Warm minimum and an ops step for the operator. The
`Machines` row in that doc describes the pool until it runs.

Doc: CI-RUNNERS

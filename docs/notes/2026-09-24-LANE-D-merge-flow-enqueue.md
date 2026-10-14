# Approved, CLEAN PRs enqueue in the tick they become READY

Doc: MERGE-CONDUCTOR

## What was measured

On 2026-09-24 the hub's pipeline-health log paged the same shape over and over:
`<PR> is APPROVE …, OPEN and CLEAN for 30m/40m/90m/110m/170m and the merge sweep
has not landed it. Last merge-sweep.log line about it: sweep never logged this PR
— the silent-skip shape` (cromford #1998, #2031, #2068, #2108, #2113, #2114,
#2130, #2131, #2141, #2150). PR-open to queued ran p50 30 min, p90 175 min.

## Why

Three things, each one enough to cost ticks, none of them named in any log.

1. **The Mergify enqueue ran inside the project merge lock.** The READY arm called
   `mc_merge_locked "$P" mc_enqueue …`. On a Mergify repo that is
   `mc_enqueue_mergify`: a label, a comment and a witness poll of up to
   `MC_MERGIFY_WAIT_S` (90 s) in 15 s steps. Every other READY worker of the
   project waited at most `MC_MERGE_LOCK_WAIT` (120 s) and then logged "another PR
   of <p> held the project merge lock … the next tick tries again". So about two
   READY PRs per project per tick got in, and the rest retried in flock's random
   order, which is where a p90 of hours comes from. The lock exists so two merges
   cannot race main; a label and a comment do not touch main.
2. **The self-enqueue that should have caught them could not pass on
   cromford.** `ae_project` (BH-1668) posts `@mergifyio queue` under a PAT with
   no lock and no wait, for every row the conductor cleared READY. Its G4 gate read
   ONE check name, `MC_AUTOENQUEUE_CHECK`, default `Build + Unit tests`, which is
   project-5's check. No cromford check carries that name, so every READY row
   there was refused `'Build + Unit tests' is absent on this head`.
3. **The page read a log nobody writes.** pipeline-health quoted
   `logs/merge-sweep.log`, whose cron line BH-1388 retired, so every stall said
   "sweep never logged this PR" whatever the conductor's reason was. And the READY
   arm's `[ "$MERGES" = 1 ] || return 0` returned without a line, so a READY row
   under a merges pause really was silent.

## What changed

- `bin/merge-conductor.sh` READY arm: on `PROVIDER=mergify` the enqueue call runs
  outside `mc_merge_locked`. Nothing after the poll merges: since BH-2199 a silent
  queue (rc 3) HOLDS the PR READY (`MERGE_HELD`, a `mergifyhold` row, one daily
  alert), so no gate read before the lock-free poll can go stale into a merge.
  (Review rounds of #2215 added a re-checked direct merge under the lock,
  `mc_merge_rechecked`, per the operator 2026-09-24; on 2026-09-25 the operator chose main's
  BH-2199 hold instead, and the rebase dropped it — the queue owns main.)
  A READY row with merges off logs `READY on <sha> and NOT enqueued: merges are off
  this tick (mode …)` once per (PR, head).
- `bin/lib/tier2-autoenqueue.sh` G4 requires the repo's ADMISSION checks: the
  `check-success` names under `queue_conditions:` in its `.mergify.yml`
  (`ae_mergify_admit_checks`, over the conductor's cached policy read). It does not
  read `merge_conditions:`, which Mergify evaluates on the batch draft. A check that
  runs only there reads `completed/skipped` on the PR head (#2220's config), and
  requiring it would refuse every row. An operator value in `MC_AUTOENQUEUE_CHECK`
  still decides alone, and the registry default is now empty. `queue_conditions`
  that name no check fall back to `Build + Unit tests`. The reader takes a block
  list indented under the key or at the key's own indent, and a one-line inline
  `[ ... ]` list (quote-aware commas). A shape it cannot read (an inline list over
  several lines, a bare scalar) is refused with one named `queue_conditions shape
  not understood` log line a day, never guessed into the fallback name. `or:` and
  `not:` subtrees are skipped, since alternatives and negations are not required
  checks; `and:` is read. An
  unreadable `.mergify.yml` refuses the row for that tick. G4 reads one unfiltered
  check-runs page per row, and a page that does not hold every run counts as
  unreadable. The POST runs under a per-PR flock that re-reads the ledger first,
  so a keyed tick and the cron tick never both ask, and a head another tick took
  to the 3-failure cap is not asked a fourth time.
- `bin/lib/keyed-wake.sh` (new): `kw_conductor <slug> <num> <why>` launches
  `MC_ONLY_PR=<slug>#<num> bin/merge-conductor.sh` detached, at most once per PR per
  `MC_KEYED_WAKE_MIN_S` (120 s). `mc_rereview_run` calls it when a detached
  re-review finishes APPROVE, so the PR is enqueued at once, not on the next */5
  tick. GitHub's own `pull_request`/`check_suite` events already ring the conductor
  through `bin/wake-loop.sh`. The cron tick stays the backstop. Knobs `MC_KEYED_WAKE`
  and `MC_KEYED_WAKE_MIN_S` are on the merge-conductor lane. Stamps older than a day
  are pruned on each wake, under the directory lock held exclusive and skipped
  when any wake holds it shared, so a lock file in use is never deleted.
- `bin/pipeline-health.sh` sweepstall: fires at max(`SWEEPSTALL_SECS`, 2 x the
  conductor's `MC_TICK_SECS` for that project). The registry default is 600, down
  from 1800. A `READY` row with nothing else named goes to the warn digest: an
  untriaged `severity:"warn"` beat, which `bin/beat.sh` spools for
  `bin/alert-digest.sh --warn-batch` (deterministic, no LLM, no page). It must not
  carry `triaged:true`, because beat.sh only routes untriaged beats by severity and
  the console ignores severity, so a triaged warn paged at once. The project whose
  cadence sets the bar is resolved from the PR's repo through `bin/fleet-conf.sh`.
  Every other state pages, except the two that are owned: `QUEUED` and a
  `STACKED_WAIT` row for the PR's current head, which are skipped. The page names the conductor's row (`conductor row <STATE> since <t>
  (<reason>)`) and its last `merge-conductor.log` line about the PR. When there is
  no row it says `no conductor row for this PR — the silent-skip shape`. A
  `STACKED_WAIT` row is skipped like a `QUEUED` one, because it is based on its
  parent's branch and waiting for that parent by design, but only when the row's
  head is the PR's current head.

## What this does not claim

Four of the PRs in the page (#2031, #2068, #2131, #2150) were stacked children,
retargeted to main when their parents merged at 17:26 and 18:39-18:40Z. #2068's
conductor row only reached READY at 20:42Z. Where it sat between 18:39 and 20:42
is in `logs/merge-conductor.log` on the hub, which this change could not read.
The next page names that state itself.

Rollout: restart lane (the hub's conductor and pipeline-health cron). Tests:
`tests/tier2-autoenqueue-test.sh` AT-24..AT-26, `tests/merge-flow-lane-d-test.sh`,
`tests/pipeline-health-detectors-test.sh` 1j-1m.

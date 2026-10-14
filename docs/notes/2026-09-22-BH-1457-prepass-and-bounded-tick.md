# BH-1457 — the resolver spends nothing on finished rows, spends cheap first, and stops

Doc: MERGE-CONDUCTOR

The hub census of 2026-09-22 14:1xZ, and the operator's two asks on it ("can we first
classify or group them so it's more bulk / cheaper", then the 53-minute tick).

## What the census said

`bin/blocked-resolver.sh` reported `candidates=785` on every tick and ended
every one of them on `reason=budget`. `state/blocked-resolver` held 586 records:
project-5 300, cromford 105, project-4 93, project-7 37, project-3 22,
project-1 16, project-2 8, project-8 4. By last reason:
conflict-unresolvable 76, head-not-reapproved 56, iron-law 39,
rebuild-plan-blocked 35, red-twice 23, test-tamper 17, rescue-giving-up 14,
plan-blocked 11, orphaned-child 10, no-verdict 9. **371 rows had never been
acted on at all, and 90 rebuild-landed + 98 RESOLVED_MERGED + 79 ABANDONED were
finished rows still on the list.**

Then, after `BR_PER_TICK` went from 4 to 50: the 14:04Z tick ran 12 rungs and
took **53 minutes** (`rungs=12/12 reason=budget` at 14:57Z), and every
ten-minute cron in between exited on "another tick is live". `oldest_untouched`
did fall 5436m → 2552m in that one tick, so the backlog clears once the rungs
actually run — the problem was never the rungs, it was what they were spent on
and how long the tick held the lane.

## What shipped

**1. A finished row leaves the list before anything is spent.** `br_prepass`
runs between `br_candidates` and `br_round_robin`, reads only this lane's own
state files, and drops a candidate whose record is ABANDONED, or
RESOLVED_MERGED for this candidate's own url. An ABANDONED row was already
terminal inside `br_one` (rc 3) but was still discovered, counted and read every
ten minutes; a RESOLVED_MERGED row was worse — it spent a whole `BR_PER_TICK`
slot and several REST reads before `br_already_merged` answered what this lane
had already written down.

Two rows deliberately do NOT retire. A RESOLVED_MERGED record whose
`resolved_url` is a different PR is a ticket that acquired a new pull request,
and a park on it is real work. And `rebuild-landed` is a finished ATTEMPT, not a
finished ticket: the rebuild it records created a PR that is a legitimate new
candidate under the same cap key. `resolved_url` is new, written by
`br_resolve_merged`; a record from before this change carries none and an absent
url is never read as a match (D11), so an old record can only fail to retire.

One `EVENT resolver_retired` per row, ever, guarded by a `retired: true` flag.
177 lines every ten minutes is the noise the lane's own "one line per episode"
rule exists to forbid; `retired=` on the tick line is the standing number.

**2. The cheapest rung goes first.** `br_cost_rank` resolves the rung the way
`br_one` will — `br_action`, and for the branch classes `br_ladder_rung` over
this ticket's own counters — and bands it: free (mechanical, regen), one call
(adjudicate, re-review), one agent round (fix-round), a whole pool build
(rebuild-fresh, rebuild-retry). The sort is stable and applied BEFORE the hotfix
rank, so rank still beats cost and cost decides inside a rank band, and
`br_round_robin`'s per-project interleave survives inside a cost band. Reading
the rung off the record rather than off the reason word matters: a conflict
whose mechanical rung is already spent IS a fix round and now sorts as one.

**3. A rung budget is not a pool-build budget.** `BR_REBUILDS_PER_TICK`
(default 4 — today's default rung budget, so a fleet at `BR_PER_TICK=4` is
unchanged) caps how many rebuilds one tick may buy fleet-wide. A capped park
answers rc 3 and looks untouched: no rung slot, no project share, no record
written, no PR closed, and its conductor hand-off is NOT released, so it comes
back next tick. `abandon-rebuild` is not counted — it closes out a ticket and
starts no build.

**4. The tick is bounded, and its unspent budget is carried.**
`BR_TICK_MAX_SECS` (default 1800, three cron periods) stops a tick from starting
new rungs once its wall clock is gone, and the rungs it was allowed but never
bought are carried into the next tick, clamped to `BR_PER_TICK`.

## Why the tick is bounded rather than concurrent

Ask (7) offered a choice: a bounded pool of concurrent rungs per project, or a
wall cap with a carried budget. The pool is not safe in this lane today:

* `br_cron_unlock` releases the LANE-WIDE scan lock from inside the FIRST rung's
  dispatch, and `flock` lives on the open file description — so the unlock in
  one subshell releases the parent's. With a pool, the first rung to reach the
  dispatch would drop the tick's single-flight guard while other rungs are still
  scanning.
* `br_use_token` installs a per-repo App installation token into the PROCESS.
  Two rungs on two repos would clobber each other's credential mid-read, and a
  wrong-token 404 reads here as "the PR has no branch".
* `NP`, `CAPSAID`, `VISITED` and `_BR_AUTH_SAID` are parent-shell ledgers a
  background subshell cannot write, so BH-870's per-project cap and BH-980's
  starvation clock would both silently stop counting.
* `mc_transition` and the hand-off release write `state/merge-conductor/` rows
  with no per-row lock.

Each is fixable and none is this ticket.

## Two things that would have been silent bugs

**A tick must always take at least one rung.** `TICK_START` is taken when the
tick takes its lock, so discovery is inside the budget — and on a fleet with 785
candidates a small cap can be spent before the first rung is dispatched. Without
the `N > 0` guard the lane would take no rung at all, for ever, and its log
would be indistinguishable from a quiet tick.

**`grep -c` prints `0` and exits 1 on an empty file.** The first cut of the
rebuild cap read the ledger as `$(grep -c . "$TICK_REBUILDS" || echo 0)`, which
on an empty ledger is the two-line string `0 0`; `[ "0 0" -ge 0 ]` is an error,
which reads as "not capped". `BR_REBUILDS_PER_TICK=0` therefore bought a pool
build, and every cap of 1 or more worked by accident from the second rung on.
Section 3d of the suite is what caught it.

## What is NOT in this change

The ticket's asks 2, 3 and 4 — carry an unchanged verdict instead of re-buying a
review, classify conflicts with `git merge-tree --write-tree` before rebuilding,
and adjudicate iron-law / test-tamper per FAMILY rather than per PR. All three
need a fetched clone of the project and, for two of them, a new cross-PR agent
round; they share one seam and belong in one follow-up. The tick line therefore
gains `retired=` and `rebuilds=` and NOT `carried=` / `mechanical=` /
`families=`: a counter that can only ever print 0 is indistinguishable from a
feature that is broken.

`budget_carry=` is deliberately not spelled `carried=`, so ask 2's verdict carry
can take that word without it meaning two things.

## Files

* `bin/blocked-resolver.sh` — `br_finished`, `br_cost_rank`, `br_prepass`, the
  pipeline between `br_candidates` and `br_round_robin`, `TICK_START` and the
  wall bound in the tick loop, `TICK_REBUILDS` and the cap in `br_one`, the
  `resolved_url` write, the tick line, and `tick-budget` in the saturation
  streak.
* `catalog/lanes.d/blocked-resolver.json` — the two new knobs.
* `tests/blocked-resolver-prepass.bh-1457-test.sh` — the suite.
* `tests/blocked-resolver.bh-1122-test.sh`, `tests/blocked-resolver.bh-980-test.sh`
  — both compare the tick line WHOLE, so both carry its new fields. Nothing was
  weakened: bh-980's drain case additionally sets `BR_REBUILDS_PER_TICK=9` so
  that its six rebuild parks still all run and the case keeps proving what it
  was written to prove (the drain ledger and the skip list) rather than
  accidentally proving the new cap.

## The fix round — three adversarial reads, and what they found

Three reviews of the first cut. The mechanisms were right and every gate was
green; the defects were all in the shapes the suite never drove.

**The candidate row was not eight fields wide.** Only `br_conductor_emit` filled
the eighth (`parked`); queue, builds, rebuilds and reviews emitted seven, and
nothing noticed because the tick loop's eight-name `read` simply left PARKED
empty. Appending a ninth column put the COST there: `br_note_untouched` reads an
all-digit string as an epoch, so `oldest_untouched` printed **29,834,966m** —
on the tick line AND on the SATURATED page — and `sort -k9,9n` keyed those rows
0, running the whole-pool-machine rungs FIRST and letting them eat the rebuild
budget. The exact inverse of the ask, in the sources most likely to be rebuilds.
Every source pads now, and `br_prepass` re-emits from PARSED fields so the width
is one function's property rather than eight printfs' promise. The suite drove
conductor rows only, through `ROWADD` → `pr-state.tsv`; it now drives the queue
source too.

**`RESOLVED_MERGED` retired too much and too little at once.** Too much: a
candidate with no url of its own was retired unconditionally, and
`br_from_builds` ALWAYS emits `-`. So a ticket whose PR merged, and whose later
rebuild then died in the pool, was dropped for ever — no ABANDONED outcome, no
ticket comment, no alert, silent after the first tick. Too little: every one of
the census's 98 `RESOLVED_MERGED` records predates `resolved_url`, so none of
them retired at all and each kept burning a slot. Both are one fix: the url-less
arm returns 1, `rebuild-*` reasons are excluded outright, and a legacy record's
url is read off its own `resolved-merged` attempt — a fact on disk, not a guess.

**A typo in `BR_PER_TICK` killed the tick.** It is the knob an operator
hand-edits on the hub and the only one on its line with no numeric guard. Every
pre-existing comparison was `[ "$N" -ge "$PER_TICK" ]`, which is an error and
not a crash — but the arithmetic this ticket added evaluated it, and `$(( ))` on
a non-number EXITS THE SHELL under `set -u`: after the pre-pass had written its
retire events and flags, before any rung, with no tick line and no ALERTS line
to say a tick had died.

**The rebuild cap counted the wrong thing.** Both rebuild rungs return 0 on
paths that enqueue nothing — the merged guard, the hold gate, a spent ticket cap
that abandons, a refused close, a duplicate race. Counting the dispatched rung
meant four refusals exhausted the fleet budget under a log line that said
"already bought 4 pool build(s)", which was false. `BR_REBUILD_BOUGHT` is set at
the one place an enqueue lands.

**The cost order undid BH-980.** Sorting globally after the interleave pins the
tick to whichever project holds the cheap rungs: measured at `BR_PER_TICK=1`,
p1 with three adjudications and p2 with one rebuild went `p1, p1, p1` where main
goes `p1, p2, p1` — and p2 then earns a STARVED page for a starvation the
ordering itself created. Cost is a WITHIN-PROJECT key now, applied before the
interleave, so round 1 of the rotation is every project's cheapest rung.

**The wall bound could not fire on the tick it was written for.** It was gated
on `N`, the rung counter, which only moves on a non-rc-3 return — and every
terminal, held, stalled, deduped and cap-refused row returns rc 3. A tick whose
rows are all held kept N at 0 and walked all 785 of them unbounded, and those
rows are not free: the hold gate reads GitHub for each. A separate `LOOKED`
counter now gates the bound; `N` still governs the rung budget.

Also: `secs=` on the tick line (the whole ask was a 53-minute number, and
`reason=tick-budget` alone does not say whether a tick ran 31 minutes or three
hours); the SATURATED alert names the ending it saw and stops advising "raise
`BR_PER_TICK`" on a lane that is time-bound; `+prepass-fallback` marks a tick
that retired and costed nothing; one `jq` pass over the record tree instead of
four forks per candidate, in the stretch of the tick the wall bound cannot stop;
the retired flag is read and written under one spelling of an empty project
(it was `$ST//x.json` vs `$ST/-/x.json`, so the flag never took and the event
fired every tick, inside the block whose comment says "ONE LINE PER ROW, EVER");
a failed flag write, a failed carry write and a failed cost sort each say so;
one cap line per tick instead of one per refused park; and `br_event` inside the
stdin-consuming loop takes `</dev/null`.

**Two things are deliberately NOT fixed here, and both are written down at the
code.** A park the rebuild cap refuses still does not age `oldest_untouched` —
#1477 carries the `BR_TICK_REFUSED` seam for it and copying its file shape here
would collide. And `.tick-budget` and `TICK_REBUILDS` are not lock-protected:
the cron lock is released at the top of the first dispatch, so two live ticks
can each hold their own cap. That window is bounded, it is the shape
`.saturation.tsv` already accepts, and the per-TICKET rebuild ledger is what
actually stops one ticket being rebuilt twice.

**Two of the four concurrency reasons were wrong and are struck** from the code
comment, `docs/MERGE-CONDUCTOR.md` and the verification-map page. An exported
`GH_TOKEN` is per process, so two rungs in two forked subshells cannot clobber
one another. And `mc_row_put` does take a flock — what is unlocked is the
get/put PAIR inside `mc_transition`, a lost-update window only for two rungs on
the same key, which the per-key lock already prevents. The decision stands on
`br_cron_unlock` alone, which is sufficient; sending the next author to fix two
things that are not broken is its own kind of wrong.

# The resolver's deterministic pre-pass and its bounded tick (`bin/blocked-resolver.sh`)

**What it is:** before `bin/blocked-resolver.sh` spends a single rung, one pass
over the candidate list drops the rows that are already FINISHED and gives every
survivor a COST, so the cheap rungs go first. Two further bounds sit on the tick
itself: `BR_REBUILDS_PER_TICK` caps how many pool builds one tick may buy, and
`BR_TICK_MAX_SECS` caps how long one tick may go on starting rungs, carrying the
rung budget it did not spend into the next one.

It exists because of the hub census of 2026-09-22 14:1xZ:

* `candidates=785` on every tick and `reason=budget` on every tick;
* of 586 state records, **98 `RESOLVED_MERGED` and 79 `ABANDONED` were finished
  rows still being offered** — an abandoned row is terminal inside `br_one` but
  is still discovered, counted and read every ten minutes, and a resolved one
  spends a whole `BR_PER_TICK` slot plus a handful of REST reads before
  `br_already_merged` answers what the lane already knew;
* rungs ran in source order, so REBUILD FRESH (plan + execute + review, a whole
  pool machine) was as likely to go first as a one-call adjudication;
* `BR_PER_TICK` had just been raised from 4 to 50, which silently made 50 pool
  builds in one tick permissible;
* and the 14:04Z tick ran 12 rungs in **53 minutes**, during which every
  ten-minute cron exited on "another tick is live" — so the raised budget bought
  latency instead of throughput.

**The pre-pass reads nothing but this lane's own state files.** No model, no gh,
no git, no jobs client, and ONE `jq` invocation over the whole record tree
(`br_record_index`) rather than one per candidate. The per-candidate loop execs
nothing. A record that will not parse costs only itself: it is indexed with an
outcome nothing matches, counted, named in a log line, and marked on the tick
line as `+index-short`.

## What retires, and what deliberately does not

| record | retired? |
|---|---|
| `outcome: ABANDONED`, the record has no `abandoned_url` (written before BH-8339, or an operator's ABANDON) | yes — the ticket-level rule: `br_one` answers rc 3 for every row under that cap key |
| `outcome: ABANDONED`, candidate url is `-`, not a PR url, or == `abandoned_url` | yes |
| `outcome: ABANDONED`, candidate url is another PR of the ticket | **no** (BH-8339) — `br_one`'s `bpr_scope` gives it a fresh ladder when it is open, and keeps the terminal (rc 3) when it is closed, merged or unreadable |
| `outcome: RESOLVED_MERGED`, candidate carries no url | **no** — `br_from_builds` always emits `-` and `br_from_rebuilds` often does, so retiring on an absent url deleted the only consumer a dead rebuild's record has |
| `outcome: RESOLVED_MERGED`, candidate url == `resolved_url` | yes |
| `outcome: RESOLVED_MERGED`, candidate url != `resolved_url` | **no** — a ticket can acquire a new PR (a rebuild's) and a park on it is real work; the row keeps today's path and `br_already_merged` decides it (today that answer comes off the record's own outcome before any repo read, which is a pre-existing slot burn this change does not close) |
| `outcome: RESOLVED_MERGED`, no `resolved_url` (a record written before BH-1457) | yes, when its own `resolved-merged` ATTEMPT names this candidate's url — that detail string is a fact on disk. A record with neither stays unretired (D11) |
| `outcome: RESOLVED_MERGED`, reason `rebuild-*` | **no**, whatever the ticket did — those rows ARE the rebuild reporting how it finished, and `br_abandon_rebuild` is their only consumer |
| last attempt `rebuild-landed` | **no** — a finished ATTEMPT is not a finished ticket; that rebuild created a PR which is a legitimate new candidate |

`resolved_url` is written by `br_resolve_merged` at the moment it resolves, and
`br_record_index` falls back to the url in the record's own `resolved-merged`
attempt when the field is absent — which is how the 98 records that predate this
change retire at all. `br_resolve_ticket_merged` writes no `resolved_url`: it
resolves because the TICKET landed somewhere else, and the merged PR's url is
not this candidate's.

A retirement is announced **once**, as `EVENT resolver_retired` plus a `retired:
true` flag on the record. 177 lines every ten minutes is the noise the lane's
own "one line per episode" rule forbids; the tick line's `retired=` is the
standing number.

## The cost bands

`br_cost_rank` resolves the rung the way `br_one` will — `br_action`, and for
the branch classes `br_ladder_rung` over THIS TICKET's own counters — so a
conflict whose mechanical rung is already spent sorts as the fix round it is
rather than as the free rung its reason word suggests.

| band | rung | what it costs |
|---|---|---|
| 0 | `mechanical`, `regen`, `abandon-rebuild`, `none` | no model |
| 1 | `adjudicate`, `re-review` | one call |
| 2 | `fix-round` | one execute-stage agent round in a worktree |
| 3 | `rebuild-fresh`, `rebuild-retry` | a whole pool build |

**Rank beats cost, and cost is a WITHIN-PROJECT key.** The sort runs BEFORE
`br_round_robin`, keyed on the project's first-appearance ordinal and then on
cost, so the interleave sees its projects in exactly the order the sources
produced them and round 1 of the rotation is every project's cheapest rung. A
GLOBAL cost sort after the interleave would undo BH-980: the tick would pin
itself to whichever project holds the cheap rungs and then page STARVED for the
one it parked. The hotfix rank is applied last of all, so a `hotfix` park goes
first whatever its rung costs (#643). The preview is advisory in every case:
`br_one` re-resolves under the per-key lock and its answer is the one that
runs.

## Why the tick is bounded rather than concurrent

The other half of the ask was a bounded pool of rungs per project. This lane
cannot hold one safely today, and ONE reason is sufficient:

1. **`br_cron_unlock` releases the LANE-WIDE scan lock from inside the first
   rung's dispatch.** `flock` lives on the open file description, so the unlock
   inside one subshell releases the parent's: the first rung to reach the
   dispatch would drop the tick's single-flight guard while other rungs are
   still scanning, and overlapping ticks rediscovering the same parks is the
   thing that guard exists to stop.
2. **`NP`, `CAPSAID` and `VISITED` are parent-shell ledgers a background
   subshell cannot write**, so BH-870's per-project cap and BH-980's starvation
   clock would stop counting. Real, but not a blocker: a pool's parent would
   update them after `wait`, the way `mc_count_inc` already does for the
   conductor's concurrent workers.

**Two reasons the first cut gave here were wrong and are struck.** An exported
`GH_TOKEN` is per process, so two rungs in two forked subshells each hold their
own and cannot clobber one another. And `mc_row_put` does take a flock — what is
unlocked is the `mc_row_get` → `mc_row_put` PAIR inside `mc_transition`, a
lost-update window only for two rungs on the same key, which the per-key lock
already prevents. Whoever builds the pool should not be sent to fix either. So rungs stay serial and the TICK is bounded.
`BR_TICK_MAX_SECS` can only stop the tick BETWEEN rungs — a fix round holds its
machine for up to `BR_FIX_LANE_TIMEOUT` and is never interrupted — and **a tick
always takes at least one rung**: discovery is inside the budget, so a small cap
can be spent before the first rung, and a lane that then took none would do
nothing for ever and log exactly like a quiet tick.

**The bound is measured on rows LOOKED at, not rungs run.** Every terminal,
held, stalled, deduped and cap-refused row answers rc 3, so a rung-gated bound
could not fire on a tick made of them — and those rows are not free, because the
hold gate reads GitHub for each. The floor it guarantees is therefore "a tick
always looks at at least one row", which is what stops a cap shorter than
discovery from making the lane do nothing for ever.

The unspent rung budget is written to `state/blocked-resolver/.tick-budget` and
read by the next tick, clamped to `BR_PER_TICK` so the budget can at most double
and an outage cannot produce one enormous tick. Only a `tick-budget` ending
carries anything: a drained tick had nothing left to do, and a tick that spent
every rung was not cut short. `tick-budget` advances the SATURATED streak
alongside `budget` — they are one condition in two words.

## How an operator reaches it

`cron/hub.cron`, the `4,14,24,34,44,54` line that runs
`bin/blocked-resolver.sh`. The tick line in `logs/blocked-resolver.log` is the
whole readout:

```
tick: candidates=785 retired=177 projects=8 visited=[…] skipped=[…] rungs=12/50 reason=tick-budget secs=1803 rebuilds=4/4 budget_carry=38 oldest_untouched=2552m
```

`candidates` is what discovery found and `retired` is what the pre-pass dropped,
so `candidates - retired` is what the loop could reach. `rungs` is over the
EFFECTIVE budget, which is `BR_PER_TICK` on any tick that carried nothing —
on a permanently wall-bound lane the carry sits at its clamp and the denominator
is twice the knob for ever, which is why `reason` and `secs` are the fields that
say whether a small `rungs=` means idle or time-bound. `+prepass-fallback` on
`reason` means nothing was retired and nothing was costed this tick.

## Knobs

### What is NOT bounded, and is known

A park the rebuild cap refuses does not yet age `oldest_untouched`: BH-1122's
walk covers rows past the break and share-capped rows, and an rc 3 from inside
`br_one` is invisible to it, so a 100-minute rebuild park held back by the cap
reads as `-`. #1477 carries a `BR_TICK_REFUSED` scratch file the parent reads to
call `br_note_untouched`; it is not on main yet and copying its shape here would
collide with it, so the code carries a TODO naming that ticket.

Two per-tick scratch files are not lock-protected and the window is accepted.
The cron lock is released at the top of the first dispatch, so two live ticks can
each read `.tick-budget` and each hold their own `TICK_REBUILDS` — up to twice
`BR_REBUILDS_PER_TICK` between them. It is bounded, it is the shape
`.saturation.tsv` already accepts, and the per-TICKET rebuild ledger is what
actually stops one ticket being rebuilt twice.

| knob | default | what it bounds |
|---|---|---|
| `BR_REBUILDS_PER_TICK` | 4 | pool builds one tick may buy, fleet-wide. The default is today's default rung budget, so a fleet at `BR_PER_TICK=4` is unchanged and the cap bites only where the budget was raised. 0 fires no rebuild rung at all. |
| `BR_TICK_MAX_SECS` | 1800 | seconds one tick may go on starting rungs, discovery included. 0 is no cap, i.e. the pre-BH-1457 loop. |

Both are declared in `catalog/lanes.d/blocked-resolver.json` and reachable
through `lane_env_apply`, so changing either is a settings row rather than a
deploy.

## What must never regress

* **A capped rebuild looks untouched.** rc 3: no rung slot, no project share, no
  record written, no PR closed, and the conductor's hand-off is NOT released —
  the release sits past that return, so the park comes back next tick.
* **A tick always takes at least one rung**, however long discovery took.
* **The pre-pass fails open.** A pre-pass that produced nothing from a non-empty
  list says so and offers every candidate uncosted; a `sort` that cannot run
  leaves the order alone. The cost column is stripped unconditionally, on every
  path, so the loop's `read` never sees a ninth column in `PARKED`.
* **RESOLVED_MERGED retires exactly one thing: the park on the PR the resolve
  was about.** A url-less candidate is NOT retired — `br_from_builds` always
  emits `-` and `br_from_rebuilds` often does, so retiring on an absent url
  deleted the only consumer a dead rebuild's record has. Neither is a
  `rebuild-*` reason, whatever the ticket did: those rows ARE the rebuild
  reporting how it finished.
* **A legacy record retires off its own attempt trail, never a guess.** The
  `resolved-merged` attempt carries the url in its detail string; that is a fact
  on disk. A record with neither field stays unretired.
* **Every candidate row is eight fields wide.** Until BH-1457's review only the
  conductor source filled the eighth, and a ninth column appended to a
  seven-field row put the COST in `parked`: `oldest_untouched` became
  ~29,000,000m on the tick line and on the SATURATED page, and the cost sort
  keyed those rows 0, running the whole-pool-machine rungs FIRST. Every source
  pads its row now AND `br_prepass` re-emits from parsed fields, so the width is
  one function's property rather than eight printfs' promise.
* **The rebuild cap counts pool builds BOUGHT, not rungs dispatched.** Both
  rebuild rungs return 0 on paths that enqueue nothing — the merged guard, the
  hold gate, a spent ticket cap, a refused close, a duplicate race — so counting
  the dispatch let four refusals exhaust the fleet budget under a line that said
  "already bought 4 pool build(s)".
* **The cost order is a WITHIN-PROJECT key.** A global sort undoes BH-980: a
  project whose parks are all rebuilds waits behind every cheaper rung in every
  other project, for ever, and then earns a STARVED page for a starvation the
  ordering itself created.
* **The wall bound is gated on rows LOOKED at, not rungs run.** Every terminal,
  held, stalled and cap-refused row answers rc 3, so an N-gated bound could not
  fire on a tick made of them — and those rows are not free.
* **`BR_PER_TICK` has a numeric guard.** It is the knob an operator hand-edits;
  without one, `$(( PER_TICK + CARRY_IN ))` on a typo exits the shell under
  `set -u`, after the pre-pass has written its retire events and before any
  tick line or ALERTS line exists to say a tick died.
* **`grep -c` prints 0 and exits 1 on an empty file.** A `|| echo 0` fallback on
  the rebuild ledger makes the count the two-line string `0 0` and the
  comparison an error that reads as "not capped" — which is exactly how
  `BR_REBUILDS_PER_TICK=0` bought a pool build in the first cut of this change.
* **Every degradation stays loud.** Three of them are fail-open by design and
  each writes one line: a scratch file the box would not make for the rebuild
  ledger (the cap is then not enforced), the same for the retired count (rows
  still retire, the number is reported as 0), and a cost `sort` that produced
  nothing (the dearest rungs stop going last). A silent one of any of those is
  a lane that looks like it is bounding itself and is not.

## Verify it works

| what | how |
|---|---|
| the whole change, end to end against a scratch `$HARNESS` | `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-prepass.bh-1457-test.sh` |
| retire: abandoned, resolved-and-matching, resolved-and-not, pre-BH-1457 records, the freed slot, the `resolved_url` write | sections 1–1g of that suite |
| cost order, and that rank still beats it | sections 2–2d |
| the pool-build cap, including 0 and the untouched capped park | sections 3–3e |
| the wall bound, the at-least-one-rung guard, the carry and its clamp, saturation | sections 4–4g |
| the tick line's shape, and that an idle tick stays quiet | sections 5–5d |
| the tick line's two other consumers | `bash tests/blocked-resolver.bh-1122-test.sh`, `bash tests/blocked-resolver.bh-980-test.sh` |
| the knobs are declared | `bash tests/lanes-registry-test.sh` (§6 and §7) |

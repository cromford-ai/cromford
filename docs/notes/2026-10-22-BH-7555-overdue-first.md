# The blocked-resolver offers a park that waited BR_UNTOUCHED_ALERT_MIN/2 first (BH-7555)

Doc: BLOCKED-RESOLVER

## What changed

On project-4 an iron-law park waited 2,277 minutes with no resolver visit. The
resolver orders one project's candidates by rung cost (BH-1457), then by
priority rank. Park age played no part. The iron-law row (an adjudication,
cost 1) sorted behind cost-0 rows that came back every tick, and
`BR_PER_TICK` or `BR_TICK_MAX_SECS` was spent before its turn. The row went
to `br_note_untouched`, the `br-untouched-<p>` alert fired, and the next tick
built the same order again.

- The new fragment `bin/blocked-resolver.d/bh-7555-overdue-first.sh` defines
  `br_overdue_first`. The driver calls it on the line that fills `CANDS`
  (`bin/blocked-resolver.sh`, the `mapfile -t CANDS` line after the rank
  pass). It is the last word on the order. `BR_ONLY_PR`, the hand-off claim
  loop and the dispatch loop read the result.
- New order: the leading hotfix rows (rank 0) first, then every row parked
  for at least `BR_UNTOUCHED_ALERT_MIN/2` minutes, oldest first, then the
  rest in the old order. Main-red rows that are not overdue do not stay ahead
  of an overdue row.
- The bar is half of `BR_UNTOUCHED_ALERT_MIN` (default 120, so 60 min). A park
  gets its visit before the untouched alert fires. There is no new knob.
- A `parked` of `-`, empty, non-numeric or in the future is never overdue.
- The pass is fail-open. If a rank lookup or the sort fails, or the row count
  out is not the row count in, the old order goes through unchanged and one
  `overdue-first:` line says why.
- "Visit" means the row reaches `br_one`. `br_one` can still refuse for its
  own reasons (the LLM day cap, a re-review in flight, a held key lock), and
  each of those logs its own line.

## Log lines

- `<p>/<rkey> [<reason>]: OVERDUE — parked <n> min (>= <t> = BR_UNTOUCHED_ALERT_MIN/2), offered first this tick`,
  one per promoted row.
- `overdue-first: <k> of <n> candidate(s) parked >= <t> min offered first (after <h> hotfix row(s))`,
  one per run that promoted a row.

## Off switches

- `BR_UNTOUCHED_ALERT_MIN=0` turns the alert off and this pass with it.
- `BR_OPT_OFF=bh-7555-overdue-first` does not source the fragment. The call
  site then uses `cat`, and the order is the old order byte for byte.

## Known limit

The age is the park's own `since`. A visit does not reset it. A park that is
still live after its visit (an adjudication answered REJECT, so the fix round
is next) is offered first again on the next tick. At `BR_PER_TICK=1`, one
such park can take every rung of its project until its ladder ends. The
default `BR_PER_TICK` is 4.

Head-of-line limit: the pass has no rotation. If a project has more overdue
rows than its `BR_PER_TICK` share, and the oldest rows stay live after each
visit, the rows past the share wait. Those rows still go to
`br_note_untouched`, so the `br-untouched-<p>` alert stays the backstop. A
per-key rotation needs a new cross-run store; a child ticket can add it if
the alert shows this in prod. Case O10 of the suite pins this limit.

## Left for C1..C4 of #7555

This note is slice C0 of #7555 (ticket items 1 and 2). It does not close the
ticket. The plan (`.harness/specs/BH-7555/plan.md`, line `SLICE: C0 of #7555`)
names the rest, and the merge close-out files each one as a child issue:

- C1: the iron-law hold comment lists each hit's name and file:line.
- C2: one alert when a project has no conductor tick for 60 min.
- C3: the watchdog alerts when the fleet snapshot is older than 60 min.
- C4 (after C1): the 30-day CHECK-HIT false-positive report and the 7-PR replay.

Test: `tests/blocked-resolver-overdue.bh-7555-test.sh`.

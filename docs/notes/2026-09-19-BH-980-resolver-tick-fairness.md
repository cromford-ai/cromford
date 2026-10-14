# The resolver's tick rotates across projects, says which ones it visited, and pages for one it has ignored for an hour

Doc: MERGE-CONDUCTOR

BH-870 spread ONE tick across the projects that have candidates. It could not
spread the tick after that one, because first appearance in the candidate stream
is a deterministic order: the same `pr-state.tsv` rows, the same builds glob, the
same queue. So every tick offered the same first `BR_PER_TICK` projects, and on a
box with more parked projects than rungs the fifth one was never reached — tick
after tick. On the hub that was project-5: 14 hand-offs and not one line in
`logs/blocked-resolver.log` for seven hours, while the lane ran every ten minutes
and reported nothing wrong.

## What changed, in `bin/blocked-resolver.sh`

**The visit ledger, `state/blocked-resolver/.last-visited.tsv`.** One row per
project, four fields, unix epochs, `0` = never:

    <project>\t<last_visited>\t<first_seen>\t<last_alerted>

`br_visited_row` reads a row (zeros for anything absent or unreadable),
`br_visited_put` rewrites one atomically — awk to a temp file in the same
directory, `mv` into place, under `flock -w 5` on
`locks/blocked-resolver-visited.lock`. The lock is held for that read-modify-write
and nothing else, never across a rung: two ticks DO overlap, because a fix round
can run for 90 minutes and the next cron fires at ten, and a lost stamp is a
project that silently keeps its place at the front of the order. A lock this box
cannot take in five seconds is not worth a skipped stamp — the write goes ahead,
which is no worse than not having the lock at all.

It is a DOTFILE on purpose. `br_from_rebuilds` globs `state/blocked-resolver/*/*.json`
and the per-project state directories live in that same directory; a visible file
is one more thing those globs would have to know to skip. The file is bounded by
`fleet.conf`: only a project that reached the candidate stream is ever written,
and the stream can only name a project `bin/project-of.sh` resolved.

**`br_round_robin` sorts by that ledger.** The awk that interleaves candidates by
project now reads the ledger in `BEGIN` and stable-insertion-sorts the project
order by `last_visited` ascending before emitting, ties keeping first appearance.
A project with no row sorts to the front (never looked at = highest priority),
and the empty-project bucket has no stamp so it sorts there too, in its own slot.
**With no ledger file every stamp is 0, the sort is a no-op, and the output is
BH-870's byte for byte** — which is what a box running this code for the first
time gets, and what section 5 of the fixture pins.

**The stamp is written BEFORE the rung, not after.** At the first candidate of a
project that reaches `br_one` this tick, `last_visited` is set to now. A tick
killed inside a 90-minute fix round has still moved its project to the back of
the order; stamping afterwards would put the same project first again on the next
tick and make the one behind it wait another ten minutes for nothing.

**The drain reads an array, not a live pipe.** `done < <(br_candidates | br_round_robin)`
became `RAW=$(br_candidates)`, one ordering call into `ORDERED`, `mapfile` into
`CANDS`, and a `for` over that array. That is what removes
`bin/blocked-resolver.sh: line 946: printf: Broken pipe`: the `break` on the
fleet budget used to close the reader while `br_round_robin` was still writing, so
awk took a SIGPIPE, its `&& return 0` never fired, and the fail-open `printf`
wrote into the same closed pipe. An array has no writer left to break. It also
gives the tick line the whole candidate list, so "which projects did this tick not
reach" is a fact rather than an inference.

**The fail-open emits once.** awk's output is captured and printed after it
succeeds. The old branch printed the whole stream AFTER awk may already have
printed part of it, so an awk that died mid-write offered the head of the
candidate list twice — two rungs, two rebuilds, one ticket. It now also `say`s
`ordering fell back to source order (awk rc=N)` and returns rc 2, which puts
`+ordering-fallback` on the tick line. A fail-open nobody can see fire is a
fail-open nobody fixes.

## The two new log surfaces

**One line per tick**, written only when the candidate stream was non-empty (an
idle tick still exits quietly, and `tests/rebuild-ledger.bh-946-test.sh` reads an
empty log as proof a refused run took no tick):

    tick: candidates=6 projects=6 visited=[p1 p2] skipped=[p3 p4 p5 p6] rungs=2/2 reason=budget

`reason` is decided by the loop's own exit, never inferred afterwards: `budget`
only when the `break` actually ran with candidates left, `drained` when the loop
ran off the end of the array — every candidate offered, whether it acted, deduped,
was share-capped or answered HELD. `+ordering-fallback` is appended when awk
failed. There is deliberately no `timeout` value: nothing in this script or in
`cron/hub.cron` kills a tick, so it could not be observed, and a `reason=` that is
wrong in one exit path is worse than a `reason=` with fewer values. The slot is
there if a timeout is ever added.

**One ALERTS line per starvation episode**, for a project that had candidates this
tick and got no look at all:

    [blocked-resolver] STARVED project-5: 14 parked candidate(s) were offered and this lane has not
    looked at the project since 2026-09-19T09:14:02Z (421 min). This tick spent BR_PER_TICK=4 on
    [project-4 project-8 cromford project-3]. Raise BR_PER_TICK in env/global.env or cap the
    busy projects with BR_PER_TICK_<PROJECT>; see the tick: lines in logs/blocked-resolver.log.

Through `bin/lane-alert.sh blocked-resolver`, with the direct `ALERTS.log` +
`beat.sh` fallback `br_lane_down_alert` uses, so a box whose harness sync has not
landed `lane-alert.sh` still pages. The age is measured from the newer of
`last_visited` and `first_seen`; a project with neither gets `first_seen` written
and nothing else, because alerting on first sight would page for every new park in
the fleet ten minutes after it was parked. `last_alerted` is the one-per-episode
guard: the line is written only while `last_alerted` is no newer than that anchor,
so an unchanged situation stays silent and a later visit re-arms it. The send
happens BEFORE the stamp and the stamp is written whatever the send answered —
`lane-alert.sh` carries its own durable half, and re-paging every ten minutes
because a beat hiccuped is exactly the noise the "ONE line" ask forbids.

## The knob

`BR_STARVE_ALERT_SECS`, default 3600, read next to the other `BR_*` knobs. A
non-numeric value falls back to the default rather than paging every tick, the
same way `br_per_tick_for` treats a bad share. It is not in
`env-templates/global.env.example` for the same reason `BR_PER_TICK` is not: the
lane's knobs are documented where they are read.

## Left alone on purpose

- A candidate whose per-key `flock -n` is held by a running fix round still exits
  0 and still counts as a spent rung. That is BH-870's rung accounting and this
  ticket did not ask to change it — but the tick line now makes it visible, since
  the project appears in `visited=` and `rungs=` shows the spend.
- `br_from_rebuilds` still caps its OWN emission at `PER_TICK` over
  `state/blocked-resolver/*/*.json` in glob order, before anything is interleaved.
  That is the next fairness gap; if a project's rebuild records are never read,
  this is where to look.

## How it is proven

    HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-980-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/resolver-per-project-budget.bh-870-test.sh

The first drives the real script against a scratch harness with six projects:
section 0 extracts `br_round_robin` verbatim and drives it as a pure function
(ledger order, no-ledger order, a broken awk, an awk that dies after a partial
write), section 1 is the ticket's own test (six parks, `BR_PER_TICK=2`, all six
visited within three ticks), section 2 pins the tick line including `drained` and
the silent idle tick, section 3 asserts no `Broken pipe` anywhere in the run,
section 4 pins the alert and its four negatives, section 5 replays BH-870's
fixture to show the first tick on a box with no ledger is unchanged. Every
assertion is on what the run did — the queue rows it wrote, the lines in
`logs/blocked-resolver.log`, the rows in the ledger, the arguments handed to
`lane-alert.sh` — never on the script's source text.

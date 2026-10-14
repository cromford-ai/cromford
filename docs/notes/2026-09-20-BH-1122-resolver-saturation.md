# A park that cannot be resolved stops spending rungs, the oldest hand-off goes first, and a saturated lane says so once

Doc: MERGE-CONDUCTOR

Three shapes of the same failure, all in `bin/blocked-resolver.sh`, all visible
in the log the whole time and none of them actionable from it.

`br_rebuild_settle`'s rc-1 arm recorded the failure, bumped a counter, logged
*"retried next tick, no counter spent"* and did that for ever. project-4 TK-1674
produced 79 of those lines, 25 in a row, each one of the four rungs a ten-minute
tick has. `br_adjudicate`'s no-verdict arm has the same shape, and each of its
ticks buys a review-stage model call and throws the answer away.

`br_from_conductor` read `pr-state.tsv` in FILE order, so the park that had
waited longest was whichever one happened to be near the top of the file.

And every one of the last 40 hub ticks ended `rungs=4/4 reason=budget` — the same
line a merely busy lane writes — while #679 sat 434 minutes past its TTL and was
never reached. The conductor's TTL re-kick answered that by re-handing the park
to the lane that already had it in its list, which rewrites the one timestamp
anybody could have read the wait from.

## STALLED: a terminal for the spending, not for the ticket

`br_stall` writes, in this order:

1. a `stalled` attempt on the cap-key record, naming what could not be resolved;
2. `.outcome = "STALLED"` and `.stalled_fp`, the park's row as one string;
3. a `resolver_stalled` event;
4. ONE line through `bin/lane-alert.sh blocked-resolver` (`ALERTS.log` + `beat.sh`
   fallback, the `br_lane_down_alert` shape);
5. one `say`.

**The state is written before the send, always.** A page that does not deliver
must still stop the spending, or the lane pays for the same answer every ten
minutes with an alert nobody got; an outcome written after a failed send would be
"paged but still spending". Nothing is closed, nothing is ABANDONED, no counter
moves — an enqueue that cannot be made is still a machine problem (BH-488), it
just stops being a free one.

The alert names the file to clear and says explicitly not to delete it:

    [blocked-resolver] STALLED tproj/TK-9: 3 identical rebuild enqueue outcomes in a row — the jobs
    queue took no row for TK-9. No rung is spent on this park until its row changes (its reason, its
    PR, its build record, or its head). Fix what that reason names, then set .outcome to "" in
    state/blocked-resolver/tproj/tproj-TK-9.json to put it back in the stream — never delete that
    file, for a closed-PR park it is the only thing that re-offers the ticket. PR: … record: …

**Identical means identical.** The enqueue streak counts on `.enqueue_why`: a
jobs client that is down and a box that will not answer are two episodes, and a
failure carrying a new reason restarts the count at 1. The adjudication streak is
the TRAILING run of `adjudicate-noverdict` attempts, so a verdict in between
resets it by construction. The attempt trail stays on the rkey record where the
other adjudication attempts live; the STALLED outcome goes on the cap key,
because that is the record `br_one` reads before it dispatches.

**"Until its row changes" is `br_stall_fp`** — `reason|url|record|head`, where the
head is a read of `state/merge-conductor/pr-state.tsv` and never a `gh` call. On
every later tick `br_one` recomputes it: equal means rc 3 (no rung, no log line,
the record and the alert already said it), different means the outcome is cleared,
a `stall-cleared` attempt is recorded and the ladder resumes with its counters
intact. A conductor re-hand-off past the TTL on the same head is deliberately not
a change — that is the loop this exists to break.

**`stalled` and `stall-cleared` are not ladder attempts.** `br_from_rebuilds` and
`br_rebuild_settle` read past them exactly as they read past `held` /
`hold-unreadable` / `hold-lifted`. Without that, a stall would displace
`rebuild-fresh-failed` as the last attempt and clearing `.outcome` would put back
a row that source no longer recognises — which would make the alert's own
instruction false.

**A terminal costs no rung.** `br_one`'s `ABANDONED` arm answers rc 3 instead of
rc 0 for the same reason: `BR_PER_TICK` counts rungs that RAN, and a terminal at
the top of a project's list used to be that project's whole tick.

## Oldest hand-off first

`br_from_conductor` decorates every `BLOCKED_HUMAN` / `RED_TWICE` row with
`(breached, since)` and sorts ascending before it emits: TTL-breached parks
first, then oldest park. The TTL is read through `mc_ttl` so `MC_TTL_<STATE>`
overrides are honoured rather than hardcoded. A row whose `since` is unreadable
sorts LAST — unknown age is not oldest. The sort is `-s` (stable), so rows parked
in the same second keep file order rather than being re-ordered by their text.

`br_round_robin` still owns the order BETWEEN projects (the BH-980 visit ledger)
and preserves the order WITHIN one, so this is the order the drain sees.

## `oldest_untouched=` and the SATURATED alert

`br_conductor_emit` takes an optional 8th argument, the epoch this PR was parked
— the row's own `since`, or the hand-off record's timestamp on the recovery path.
It rides out as an 8th tuple field. The ROW's `since` is the durable park age;
the hand-off file's timestamp is not, because `mc_handoff_record` rewrites it on
every re-kick. Every other source prints 7 fields and an absent 8th reads as
unknown, never as 0.

The drain keeps the minimum epoch among candidates it never DISPATCHED — the
share-capped ones and everything from the budget break to the end of the list. A
row that answered rc 3 was looked at and is not untouched. The tick line gains it
as its last field, `-` when nothing was left or none of it carried an age:

    tick: candidates=2 projects=2 visited=[p1] skipped=[p2] rungs=1/1 reason=budget oldest_untouched=67m

`state/blocked-resolver/.saturation.tsv` (a dotfile, same reason as the visit
ledger) holds `streak <n> alerted <0|1>` plus one `rungs <project> <n>` row per
project accumulated over the streak. It is rewritten whole with tmp+`mv` at tick
end. No lock: two overlapping ticks can at worst double-count one tick, which
moves the page one tick earlier, and a lock held across a tick end would be a
queue (D33). A tick that ends on `budget` bumps the streak; any other end —
`drained`, or an idle tick with no candidates at all — resets it to zero. At
`BR_SATURATED_TICKS` with `alerted=0` the lane pages once:

    [blocked-resolver] SATURATED: 12 consecutive ticks ended on reason=budget. candidates=710
    rungs/tick=BR_PER_TICK=4 oldest_untouched=434m skipped=[…] top rung consumers over the streak:
    project-5:18 project-4:12 project-3:9. At this rate candidates ÷ (rungs×6/h) = 710 ÷ 24 ≈ 30h to first
    touch. Raise BR_PER_TICK in env/global.env (the arithmetic is in env-templates/global.env.example)
    or cap the busy projects with BR_PER_TICK_<PROJECT>. bin/merge-conductor.sh will not re-hand-off
    stuck parks while this stands.

With `BR_PER_TICK=0` the arithmetic clause reads `BR_PER_TICK=0: nothing is ever
touched` instead of dividing by it. The `alerted` flag is written whatever the
send answered (the STARVED precedent): `lane-alert.sh` carries its own durable
`ALERTS.log` half, and re-paging because a beat hiccuped is the noise "one line"
forbids.

## The marker the conductor reads

The same tick writes `state/blocked-resolver/.saturated` and removes it on the
first tick that ends for any other reason. The conductor reads it with `-e` in
two places, both through `MC_RESOLVER_SAT` in `bin/lib/merge-conductor-lib.sh`,
and writes nothing:

1. **The per-PR STUCK page** (`mc_stuck_check`). A park past its TTL pages
   *"waiting on bin/blocked-resolver.sh to drain the park"*, which sends the
   reader to a lane that is already out of rungs and has said so in its own
   alert. While the marker stands the page carries the pointer to that alert, so
   the CRITICAL a person actually receives names the lane-wide backlog instead of
   reading as one stuck PR. Only the two park states take the clause; every other
   stuck line is untouched.
2. **The re-kick** (`stuck_rekick`'s `BLOCKED_HUMAN | RED_TWICE` arm in
   `bin/merge-conductor.sh`). Present means `mc_handoff_record` is NOT called, so
   the hand-off record stands and the one timestamp the wait can be read from is
   not reset; the log line says so.

Absent, both are today's branch byte for byte. One writer, two readers, no lock
and no new flag — deleting the marker restores the old behaviour, and a stale one
can only survive while the resolver is not ticking at all.

## The knobs

`BR_ENQUEUE_FAIL_MAX` (3), `BR_ADJ_NOVERDICT_MAX` (3) and `BR_SATURATED_TICKS`
(12) are read through `br_knob_num`: empty falls back silently, and a 0 or a
typo falls back with one `say` line naming the variable. An explicit 0 is treated
as a typo on purpose — on the two stall knobs it would stall on the first
failure, and on the streak it would page every tick. All three, plus
`BR_PER_TICK` and its arithmetic, are in `env-templates/global.env.example`.

**`BR_ENQUEUE_ALERT_AFTER` is REMOVED.** It paged once at six consecutive
failures (BH-488); with a stall at three that page is unreachable by default, and
two alert paths for one condition is worse than one. Its `.enqueue-alerted`
marker file goes with it — nothing reads it any more, and an old one left on a
box is inert.

## How it is proven

    HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-1122-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-488-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-980-test.sh

Sections 1-5 and 7 of the first drive the real script end to end against a
scratch `$HARNESS`; section 6 drives `mc_stuck_check` and reads the arguments the
page handed `bin/lane-alert.sh`, then extracts `stuck_rekick` verbatim from
`bin/merge-conductor.sh` and drives that. Section D of the BH-488 suite is the
contract this ticket reversed and now pins the new one; section 2 of the BH-980
suite carries the tick line's new field.

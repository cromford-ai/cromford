# The attempt row read is memoised per tick, and one outage latches the tick

Doc: MERGE-CONDUCTOR

## What was wrong

`mc_attempt_has` (`bin/lib/mc/locks.sh`) answers a file miss with a
`GET /api/pr-attempts` when `pr-state-rows` is on. Two things cost more than
they should:

- A line missing from the file cost one GET every time it was asked, even when
  this tick had already been told there is no row.
- An outage (rc 1) called `pr_rows_trip`, which sets a shell variable. The
  conductor runs every PR as `pr_worker "$ROW" &`, so the latch died with the
  worker that tripped it. Every other worker paid its own GET, and its own
  connect timeout, before latching its own copy.

## What it does now

When `MC_TICK_ID` is set (the conductor exports it), two files in
`MC_TICK_DIR` carry state across the tick's workers:

- `<tick>.attempt-miss` holds the lines the worker answered 404 (rc 2) for. A
  line in it is answered rc 1 with no GET. Misses only: a hit still warms
  `attempts.txt`, and the file is read first, so a memoised miss never hides a
  later `mc_attempt_put`.
- `<tick>.pr-rows-down` is created on the first outage, with noclobber. From
  then on `mc_attempt_has` and `mc_attempt_put` trip the process latch and make
  no request for the rest of the tick. `mc_attempt_put` still writes the file
  line. Only the worker whose create won logs one line:
  `pr-state-rows unreachable — row reads/writes latched off for tick <id>`.

An outage is still never "already attempted": it answers rc 1 and is not
memoised as a miss. Both files are per tick, so the next tick asks again, and
`mc_tick_gc` prunes them after a day. Without `MC_TICK_ID` (blocked-resolver
and other callers) nothing changed.

Pinned by `tests/attempt-tick-memo.bh-1831-test.sh`.

## Not in this change

This change is item 4 of BH-1831 only. It is part of #1831 and does not close
it. Items 1 to 3 change code that exists only on PR #1635 (BH-1387), which is
still open, so each is its own child issue, blocked on #1387, carrying its
red-first test:

- #1839: the BH-1677 / BH-1670 file-only attempt sites and the scope-grep test.
- #1840: a keyed tick routes a woken PR's held row through the held-page path.
- #1841: the conductor key case, normalised on both sides.

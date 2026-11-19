# BH-9762: the main-red breaker files only from one consistent flag read

Doc: MERGE-CONDUCTOR

## Why

Issue #9762 was filed as "main is red since  (workflow `unknown`, sha ``,
reason ``)" with the marker `<!-- main-red-breaker: example-org/cromford@ -->`.
Main was green: Harness CI on a7d3f50b answered `success` at 20:35Z, and the
issue was filed at 20:40:17Z.

`bin/main-red-breaker.sh` read the flag in its loop, then `pause` ran its
GitHub calls. In that window `bin/main-red-detector.sh` removed the flag
because main went green. `file_ticket` and `compose` then read the live flag
again, and every field was empty. The key was `<slug>@`, so the ledger row and
the marker search both missed, and the lane filed a blank ticket.

## What changed

- The loop copies the flag once per repo per tick to `$TMP/flag-<skey>`. The
  loop, `file_ticket` and `compose` read only that copy. The tick's EXIT trap
  deletes it.
- If the flag goes away before the copy, the loop logs
  `the flag went away before it was read — skipped` and acts on nothing.
- `file_ticket` refuses an empty `since`.
- Before the issue POST, `file_ticket` checks that the live flag still carries
  the copy's `since`. If not, it logs
  `ticket: the flag cleared or changed mid-tick — nothing filed`. It writes no
  `main_red_hotfix` row, no `.warned` file and no lane alert. The next tick
  acts on the new flag.
- A rewrite with the same `since` and a new sha (the detector keeps `since` on
  a new red sha) still files once, with the copy's fields.

The detector's flag write stays as it is. No knob, row or env var changed.

## Tests

`tests/main-red-breaker-flag-race.bh-9762-test.sh`, cases A to F, 0 vendor
calls. `tests/main-red-breaker.bh-8706-test.sh` is unchanged and green.

# BH-8554: one owner for an empty lead BLOCK (U13-EMPTY)

## The defect

An empty lead BLOCK is a lead BLOCK report with no `^- \[BLOCK` line.
`bin/lead-review-land.sh` withholds it and logs "BLOCK report has no finding
line". Two Tackler families saw the same stall:

- The queue family reads that log line and emits `pr-empty-block`. U13-EMPTY
  re-requests the lead review; past `UNBLOCK_EMPTY_BLOCK_MAX` U13-EMPTY-CARD
  cards it.
- The review family read the same standing BLOCK and emitted
  `lead-block-unrouted`.

The two records had different decision keys, so both claims succeeded. Two
paths gave two actions on one stall:

1. 0 BLOCK lines. U5 needs `block_lines > 0`, so the record fell to the U12
   fallback card. Result: a U13-EMPTY re-request plus a U12 card.
2. Indented BLOCK lines only (`  - [BLOCK x]`). The collector read BLOCK lines
   with `^\s*- \[BLOCK`; land reads `^- \[BLOCK`. Land withheld the report as
   empty, and U5 posted the indented lines. Result: a U5 post plus a U13-EMPTY
   re-request.

## The decision

U13-EMPTY (then U13-EMPTY-CARD) is the one owner of an empty BLOCK.
`bin/lib/unblock/collectors/review.sh`:

- reads BLOCK lines with land's test, `^- \[BLOCK`, so the two families agree
  on every body;
- emits no record for a whole, readable report with 0 such lines and no
  `- outcome cap: ` line. Its `logs/unblock.log` review line adds
  `empty_owned=<n>:<pr,pr>` for those PRs.

Unknown is not empty: a cut report, a standing note with no `lead-job:` token
or an unreadable artifact still gives a record, as before.

The rule notes of U5 and U13-EMPTY name the owner. No predicate, key or action
changed.

## What is left

A legacy cap-only report (a `- outcome cap:` line and 0 BLOCK lines) is also
withheld by land, so U6 and U13-EMPTY can both act on it. It stays as it is:
since BH-8338 a blocking cap writes its own `- [BLOCK wrong-data] outcome cap:`
line, so land no longer withholds a new one.

## Test

`tests/unblock-empty-block-owner.bh-8554-test.sh` runs one empty BLOCK through
both real collectors and the real `ub_rules_eval`, and through
`bin/unblock.sh tick` in act mode: 1 claim, 1 action (U13-EMPTY).

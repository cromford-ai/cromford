# A human MERGE verdict row on the live head lifts a bot's comment BLOCK (BH-4468)

Doc: MERGE-CONDUCTOR

## What was wrong

`bg_scan` consulted the verdicts table for a standing lead/human MERGE row only
on the CHANGES_REQUESTED path (`bg_cr_standing`). A comment BLOCK cleared only on
the same login's UNBLOCK/CLEARED, the same machine login's head-bound
`VERDICT: APPROVE`, or a newer head. On 2026-10-04 `cromford[bot]` BLOCKed
PR #4175 at 12:27Z, the operator's MERGE row #576 then stood on that head, and every
lane still logged `MERGE_REFUSED block-gate`. The autopilot does not re-review a
head it already answered, so only an empty re-head commit freed it.

## What changed

- `bin/lib/block-gate.sh` `bg_bot_lift`, called in `bg_scan_read` after the
  walk: every pending block whose login passes `bg_bot_login` is dropped when
  `vd_standing` answers a `lead`/`human` MERGE or MERGE-WITH-NOTES row on this
  exact head. A person's block is never dropped this way.
- Each lift writes one line to `logs/block-gate.log`:
  `block-gate: bot BLOCK <comment id> lifted by human verdict #<row id> (…)`.
  Stdout (the answer every lane parses) is unchanged.
- The table is asked at most once per scan, and only when a machine block is
  still pending. No row, a row on another head, a `box` row, or a failed read
  lifts nothing.
- `docs/MERGE-CONDUCTOR.md` section 17, "How a block is cleared", gains clear 4.

Pinned by `tests/block-gate-human-over-bot.bh-4468-test.sh`.

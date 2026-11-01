# BH-8766: the Tackler waits under a rule's own threshold, and on an open parent

Ticket: BH-8766 (r7: the r3-r6 code on a fresh branch from main bd9f7537, after PR #8773 was abandoned).

## What changed

- The rule engine (`bin/lib/unblock/rules.sh`) has a new decision, `wait`.
  A rule file can name its wait thresholds in `match.wait`:
  `[{"pred": "<an entry of match.all>", "under": "<predicate>"}]`. A rule
  waits when some `under` reads T and every other `match.all` entry reads T.
  An `under` that reads F or U never waits. The first rule by priority that
  matches or waits wins. A `pred` that is not in `match.all`, or an `under`
  that reads outside the record, refuses the whole load (rc 2).
- `match.wait` is on U13-STARVE (minutes and passes), U13-RESTAMP
  (`restamp_idle_min`), U13-REACH (`reach_stuck_min`), U4-standing-approval
  (`approved_idle_min`) and U8 (`hung_min_threshold`). `match.all` does not
  change in any file.
- The tick (`bin/unblock.sh`, `ubt_decide`) makes no claim, calls no seam
  and spends nothing on a `wait`. It writes one line
  `wait <rule> <subject> [<head12>]: <under predicates>`. The tick line adds
  `waited=<n>` when n > 0. The next tick reads the record again.
- The starve collector (`bin/lib/unblock/collectors/infra.sh`) emits no
  `ticket-starved` record under either starve threshold. It reads the
  ticket's newest pool record: `plan-blocked.after` with no
  `plan-blocked.released`, or a `BUILD_DEFERRED stack-wait ... Blocked-by #N`
  RESULT. A ticket that waits on an open parent gets no record. Each skip is
  one `starve-skip <p> <KEY>: <reason>` line.
- An open parent with no progress for `UNBLOCK_STACK_PARENT_STALE_H` hours
  (default 24) is one `stack-parent-stuck` record. U12 cards it, and the card
  names the parent.
- An unread parent holds the record only while the ticket has been queued
  less than `UNBLOCK_STACK_PARENT_STALE_H` hours. After that the record goes
  out with `dep_unread`. A product-board project (fleet.conf `board_prefix`
  not `-`) gets no GitHub parent read: its parents are unread.
- More than `UNBLOCK_STACK_PARENT_MAX` parents (default 5) is not dropped. No
  parent is read, and the list counts as unread.
- A card whose recommended option starts with the word `wait` goes out as
  `lane-alert.sh --severity warn`, not `--critical`. The option is read only
  when `recommendation` is 1 to the option count.

## Why

Cards u-5e109c (BH-8325, 51 min, 1 pass, waiting on BH-8324), u-ff49fb (PR
#8663, idle 5 of 20 min) and u-b36998 (#8829, idle 1 of 20 min) paged
CRITICAL. In each case the rule that owns the record had only to wait.

## Knobs

- `UNBLOCK_STACK_PARENT_STALE_H` (int, hours, default 24, 1..336).
- `UNBLOCK_STACK_PARENT_MAX` (int, parents, default 5, 1..50).

## Tests

- `tests/unblock-rule-wait.bh-8766-test.sh` (engine, rule files, tick).
- `tests/unblock-starve-dep.bh-8766-test.sh` (collector, card severity,
  BH-8325 replay through the tick).

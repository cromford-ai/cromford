# The resolver resets its ladder when a PR's head moves after the last counted rung (BH-7660)

Doc: MERGE-CONDUCTOR

## Problem

`bin/blocked-resolver.sh` closed a PR as ABANDONED about 30 minutes after a
person pushed a new head to it. Every counted rung had run on the old head.
The supersede guard (`br_supersede_guard`) only delays a close after a new head
(the settle window, `BR_SUPERSEDE_SETTLE_SECS`, 1800 s). It does not reset the
counts. The record kept no head per rung, so no code could tell "rungs on the
old head" from "rungs on the new head".

## What changed

1. `br_record` (`bin/lib/br/record.sh`) writes `rung_head` and `rung_pr` on a
   `mechanicals`, `regens` or `fixrounds` bump: the caller's head, else the
   head the rung last read (`sup_head`). The attempt gets a `head` field too.
2. New module `bin/lib/br/headgate.sh` (`# module: headgate after: record
   ladder`). `br_head_gate` runs before the two ladder closes: in `br_abandon`
   (every caller) and before the supersede close in `br_rebuild_fresh`. It
   reads the PR once over REST.
   - rc 0, close as before: no PR url, PR absent or not open, head equal to
     `rung_head`, to this lane's own fix-round push (`fix_head`), or to the
     head the ladder was already reset to once (`ladder_reset.to`), or a
     record with no `rung_head` for this PR (a legacy record).
   - rc 5, nothing closed: the head moved. `br_head_reset` sets `mechanicals`,
     `regens` and `fixrounds` to 0, adds 1 to `head_resets`, writes one
     `head-reset` attempt and `ladder_reset {url, from, to, at, base}`, then
     one `EVENT resolver_head_reset` line. `rebuilds`, `rebuild_jobs` and
     `adjudications` stay. The next tick climbs the ladder from rung 1 on the
     new head. One reset per foreign head.
   - rc 5, nothing closed: no real rung ran (all counters 0, and the newest
     real attempt is a `*-blocked` one from `br_setup_blocked`).
   - rc 75, nothing closed or written, retried next tick: the head could not
     be read, is not a full sha, or the reset write failed.
3. `br_cap_rows` takes the record as an optional 8th argument. For `fixround`
   it subtracts `ladder_reset.base.fixround` from the `pr_attempts` count of
   the same PR. Without it the rows (counted across every head) undo the reset
   on the next tick. `br_fix_round` passes it.
4. Both close comments end with one facts paragraph (`br_close_facts`): the
   judged head, the head of the last counted rung, the counts since the last
   reset, the ticket-wide adjudicate and rebuild counts, and the number of
   attempts that could not start.

## Not changed

No new knob. The settle window is unchanged. The conductor row is not touched
on a reset. Closes that are not a ladder outcome (`stale.sh` re-plan, the
`cirepair.sh` close of an earlier parked PR, a person's HOLD) are not gated.

## How to check on a box

- `grep 'EVENT resolver_head_reset' /root/harness/logs/blocked-resolver.log`
- `jq '.rung_head, .ladder_reset, .head_resets' /root/harness/state/blocked-resolver/<project>/<cap-key>.json`
- Suite: `tests/blocked-resolver-head-gate.bh-7660-test.sh`

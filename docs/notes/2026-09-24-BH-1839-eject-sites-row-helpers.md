# The BH-1677 / BH-1670 attempt sites go through the row helpers

Doc: MERGE-CONDUCTOR

## What changed

Follow-up to BH-1831 item 1. #1635 (BH-1387) routed the attempt ledger through
`mc_attempt_has` / `mc_attempt_put` (`bin/lib/mc/locks.sh`). These helpers write the
`attempts.txt` line and also keep a `pr_attempts` row twin. BH-1677 and BH-1670
landed after #1635's base, so their sites still read and appended the file
alone. They now use the helpers:

- `mc_eject_conflict_note` (`bin/lib/mc/queue.sh`): the `ejectconflict` read and write.
- `eject_rebase_arm` (`bin/lib/mc/rebase.sh`): the `ejectconflict`, `ejectrebase`
  and `rebase` reads, the `ejectrebase` mark and both `rebase` marks. The
  `ejectrebase` mark is still written before the spawn (mark first). Both
  rollbacks were already `mc_attempt_clear`, which deletes the row too.
- `eject_rebased_note` / `eject_rebased_moved`: the `ejectrebase` and
  `ejectrebased` reads, and the `ejectrebased` write.
- `mc_stack_follow`: the `stackfollow` write.

`mc_eject_strikes` (the awk count over the file) is unchanged. A row hit
warms the file line back, so the count still sees an `ejectconflict` that
came back from the row.

## Why

If `attempts.txt` was lost, these heads forgot they had been tried. That could mean a
second out-of-budget rebase, a second `EJECT_REBASED` audit, or a second
`EJECTED_CONFLICT` line. With `flags/pr-state-rows` up, the row now answers.
With the flag down, the file lines are byte-identical to before and no
request is made.

## How it is pinned

`tests/attempt-scope-grep.bh-1839-test.sh` runs the BH-1387 scope grep
(`grep -nE 'grep -q?xF [^|]*\$MC_ATTEMPTS|>> *"\$MC_ATTEMPTS"'` over
`bin/merge-conductor.sh bin/lib/mc/*.sh`). It requires every hit to be one of the
allowlisted kinds (`identityalert mergefail requeued cirerun apread mergetree
lanefail`) or to sit inside a helper body in `locks.sh`. It matches by kind or by
enclosing function, not by line number. The suite also drives
`mc_eject_conflict_note`, `eject_rebased_note` and `eject_rebase_arm` against a
curl shim, with the flag up and with it down.

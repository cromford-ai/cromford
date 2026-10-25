# The iron-law ACCEPT is the DB row only; the marker file is gone (BH-7804)

Doc: MERGE-CONDUCTOR

Slice C4 of #4157. C0 (BH-4157, PR #7581) made the head-bound iron-law ACCEPT a
jobs-DB row and kept the old file as a dual write. This slice removes the file.

## What changed

- `bin/blocked-resolver.sh`, the ACCEPT arm of `br_adjudicate`: it writes the
  `ledgers` row kind `ironlaw-head-accept`, key `<owner/repo>#<pr>@<head40>`
  (`ila_put`, `bin/lib/ironlaw-carry.sh`), and no
  `builds/<rec>/iron-law-accepted-<sha>` file. A build record is no longer a
  precondition: the row needs only the PR url and the head.
- `bin/lib/br/opt/family.sh`, `br_opt_family_pre`: the family carry writes the
  row (source `family`) and no file. When the row cannot be written, the carry
  returns rc 0 with no side effect: no model call, no comment, no attempt, no
  `uses` bump, no count. The next tick offers the carry again. Before, a file
  write failure returned rc 1, and the lane then bought a model ruling.
- `bin/merge-conductor.sh` and `bin/merge-sweep.sh`: the file-marker check is
  deleted. `mc_ila_accept` and the sweep's `ila_gate` block (the DB row) and
  the BH-4474 fingerprint carry (`ilc_covered`) are the only ACCEPT readers.
- `bin/lib/ironlaw-carry.sh`: `ila_record_say` is deleted (no caller).
- `catalog/lane-run-inputs.d/blocked-resolver.rw` and `merge-conductor.ro`: the
  `iron-law-accepted-*` token is removed.

## A paid ruling survives a DB outage

C0's ASSUMPTIONS A1 named the risk: "a DB outage would then lose a paid
adjudication". The new fragment `bin/blocked-resolver.d/bh-7804-ila-pending.sh`
answers it:

- `br_ila_accept_write`: when `ila_put` fails, the ruling is kept as
  `.ila_pending = {url, head, at}` in the resolver record json
  (`state/blocked-resolver/<p>/<rkey>.json`). Log line:
  `ADJUDICATED ACCEPT — DB accept NOT recorded; kept as pending in the record,
  retried next tick with no model call`.
- `br_ila_pending_retry`: the "already adjudicated once" branch of
  `br_adjudicate` asks it first, for an `iron-law` park only. It writes the row
  and clears the pending (`pending ACCEPT recorded`), keeps the pending on a
  second failure or an unreadable head, and drops it (then the rung below runs,
  as before) when the pending names another PR url, a malformed head, or a head
  the PR has left. Observe mode says `WOULD retry pending ACCEPT` and writes
  nothing. The retry makes no model call and spends no counter.
- `BR_OPT_OFF=bh-7804-ila-pending` turns the fragment off: the ACCEPT arm then
  calls `ila_put` directly and says `NOT recorded` on a failure, with no
  pending.

`br_save`'s ledger mirror does not carry `.ila_pending`, so a wiped hub loses a
pending. That costs one fix round, never a false unpark.

## Legacy marker files

There is no backfill. A head ACCEPTed before C0 (2026-10-21) has a marker file
and no row. After this change it parks again, unless the BH-4474 fingerprint
rows (recorded since 2026-10-04) carry it. Old marker files stay on disk; no
code reads them.

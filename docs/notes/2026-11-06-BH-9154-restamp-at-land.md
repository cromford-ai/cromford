# The schema restamp never moves a reviewed head (BH-9154, Fix 2 of #9066)

Doc: MERGE-CONDUCTOR

## What changed

- `pq_restamp` (bin/lib/mc-prequeue.d/restamp.sh) has a new answer,
  `deferred-land <n>`. The pre-queue hook gives it when the head has stale
  stamp fragments AND an approval is bound to that head (the READY arm's
  `VERDICT=APPROVE` with `REVIEWED` = the head). It pushes nothing and logs one
  line a head:
  `<key> SCHEMA_RESTAMP deferred-land head=<h12> new=- main=<m12> renames=<n> reason=...`.
  The attempts mark is `restampdefer <key> <head>`. `pq_gate`
  (bin/lib/mc-prequeue.sh) answers `rebase` for `deferred-land`, so the READY
  arm moves the row to NEEDS_REBASE and the conductor rebase (`mc_rebase`)
  writes the restamp in its one push. A head with no approval bound to it is
  restamped and pushed as before.
- `mc_rebase` (bin/lib/mc/rebase.sh) calls the new `mc_rebase_restamp` after
  the main merge, the regenerate and the migration renumber, and before the
  gates and the one push. It runs `sr_apply` on the merged worktree. A stale
  head gets one restamp-only commit on top of the merge, so the land rebase,
  the NEEDS_REBASE rebase and the eject rebase all push the restamp in the
  push they already make. The log line is
  `<url> rebase: SCHEMA_RESTAMP land head=<h12> new=<n12> renames=<n>`.
  `restamp_same` (unchanged) carries the lead verdict across that head, and the
  ledger rebind runs as for any clean main merge.
- An `sr_apply` refusal in `mc_rebase` answers rc 2 (the "gate red, not pushed"
  answer). Nothing is pushed. It writes the `restampfail <key> <head> <newest
  stamp at main>` attempts mark that the pre-queue hook already reads, so the
  hook then holds that head too. One line a head:
  `<url> rebase: SCHEMA_RESTAMP land refused head=<h12> reason=... — not pushed`.
- The knob is the existing `MC_SCHEMA_RESTAMP` (default 1). At 0 neither half
  runs. A stacked parent merge (`base` other than main) is not restamped.

## Limits

- The land rebase arm (`land_rebase_arm`) moves only WAIT_CI, WAIT_REVIEW and
  HEAD_MOVED rows. A READY head that is stale and reviewed reaches the
  conductor rebase only through the `pq_gate` `rebase` answer (NEEDS_REBASE).
  It does not go to the queue with its stale stamp.
- The pool rebase twin (`rebase_job_run`, bin/lib/rebase-job.sh, under
  REBASE_ON_POOL) does not restamp. Under REBASE_ON_POOL the pre-queue hook
  holds a stale head as before (no change).

## Tests

tests/restamp-land.bh-9154-test.sh (R1-R8).

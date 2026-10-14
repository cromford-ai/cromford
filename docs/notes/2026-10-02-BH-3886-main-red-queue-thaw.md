# The merge-queue freeze thaws on finished greens and green main pushes (BH-3889, part 2 of BH-3886)

Doc: MERGE-CONDUCTOR

## What changed

New `bin/lib/main-red-queue-thaw.sh`. `bin/main-red-detector.sh` sources it and
calls its two hooks (the BH-3888 contract). The detector itself is unchanged.

- **`mrqt_clear_ok <slug> <flagfile>`** decides whether a `reason=queue` flag
  clears on a tick where main's own required runs are green. The flag thaws
  when any of these holds:
  - the queue was read (`QREAD=ok`) and a green batch was created after the
    newest counted red batch (`QGREEN_T > qred_t=`),
  - the queue was read and a green batch finished after that red finished
    (`QGREEN_DONE > qred_done=`),
  - a green `push` or `workflow_dispatch` run of a required workflow on main
    (`SKIP_RE` off, `schedule` never counts) was created after the red finished
    (`qred_done=`, or `detected=` when the flag has no finish).
  A flag with no `qred_t=` (raised before BH-3888) keeps the old comparison
  against `detected=`, unchanged. The log says either
  `queue freeze thawed — <why>` or `... bin/lib/main-red-queue-thaw.sh holds it — <why> — flag left as it is`.
- **`mrqt_stand_down <slug>`** drops a red queue verdict before a raise when a
  green push or dispatch run of a required workflow on main was created after
  the newest counted red finished (`QRED_DONE`, or the red's created_at from
  QVERDICT column 10 when GitHub gave no finish). The log says
  `<n> red merge-queue batches, but a push run of Harness CI passed on main at <t> on <sha> ... — the queue arm stands down`.
- The lib makes no gh call and writes nothing. It reads this tick's `RUNS` and
  `Q*` globals, so the BH-1927 confirming re-read gets the same answer.

Pinned by `tests/main-red-queue-thaw.bh-3886-test.sh`, which drives the real
detector on the 2026-10-02 pages in `tests/fixtures/bh-3886/`.

## Why: the 2026-10-02 freeze that could not clear

- 05:37:50Z: batch 36969794399 starts. It fails at 05:53:34Z, the third
  independent red batch.
- 05:54:14Z and 05:54:23Z: batches 36971026756 and 36971039150 start. Both pass,
  at 06:09:03Z and 06:09:28Z.
- 06:01:34Z: the detector raises the freeze.
- 06:09:50Z and 06:09:57Z: push runs of Harness CI on main (b38a57c9, 78cd5df9)
  pass at about 06:11Z.

**Why the 05:54Z greens were not counted.** At the 06:01:34Z tick both greens
were still in progress, and the walk only reads completed runs, so the freeze
went up. Once they finished, the clear compared their created_at (05:54:23)
with the flag's `detected=` (06:01:34). That compare can only be beaten by a
batch created after the freeze, and nothing merges while merges are frozen. So
no newer batch could ever be created, and the green pushes on main were ignored
by rule. Comparing against the newest red batch itself (its created_at and its
finish) instead of the freeze time ends the deadlock.

## INTENT CONFLICT (declared)

The detector's header (`bin/main-red-detector.sh`, the queue arm paragraph) and
its clear-branch comment say main's own push runs "are fast checks and prove
nothing about the corpus". BH-3886 reverses that: a green push on main is proof.
This lib follows the ticket, but only for a run created after the newest
counted red batch FINISHED. A green push older than that (the Q1 case) still
proves nothing. That header sentence is now stale. It lives in the contract's
file, which this ticket does not edit, so the fix is follow-up text.

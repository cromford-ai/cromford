# The tier stops deciding who merges: tier_gate_mode (BH-4579, tracer of BH-4572)

Doc: MERGE-CONDUCTOR

## What changed

the operator, 2026-10-05: retire the tier-2 human sign-off. A review's TIER is still
computed and recorded. By default it no longer decides who merges.

- `bin/lib/tier-gate.sh` (new). `tg_mode <project>` reads the settings row
  `tier_gate_mode.<project>`, then `tier_gate_mode`, and falls back to `off`
  when neither row exists. It trims and lowercases the value. `tg_holds
  <project> <tier>` returns 0 (hold) when the mode is `human` and the tier is
  not 1. An unreadable row, or a value other than `off|human`, also holds, for
  every tier. It pages once per (project, UTC day) through `bin/alert-line.sh`
  and stamps `state/tier-gate/page-<project>-<day>` after the page is sent.
  There is no file flag. Set the row with
  `bin/jobs-client.sh setting-set tier_gate_mode[.<project>] off|human`.
- The APPROVE hand-off in `bin/lib/rb/pr.sh` (`# >>> verdict at review`) and
  its settle twin in `bin/lib/rb/result.sh` (`# >>> verdict artifact`) ask
  `tg_holds` before `merge_queue_put`. A hold logs
  `APPROVE not enqueued: tier_gate_mode=<mode> (<src>) holds tier <TIER>` to
  the build's pipeline.log and writes no row. Both blocks are gated, because
  the twin would otherwise enqueue what the first block held. A tree without
  the lib enqueues as before and logs `tier gate lib not loaded`.
- `human` holds ONLY that run-build hand-off. `bin/merge-sweep.sh` (no tier
  filter) and the conductor's `ae_project` in `bin/lib/autoenqueue.sh` do not
  ask `tg_holds`, so a held tier-2 APPROVE can still be landed by either.
  Gating them is #5035 (BH-4572.4); until it merges, `human` is not a merge
  hold.
- `bin/lib/tier2-autoenqueue.sh` is now `bin/lib/autoenqueue.sh`. Its ledger
  keeps the path `state/tier2-autoenqueue.txt`, so in-flight `posting` lines
  are not orphaned. The rename made it a new lib to
  `tests/lib-root-literal-ratchet.bh-2613-test.sh`, so its one `/root/harness`
  fallback in `_ae_home` became `${MC_H:-${HARNESS:-${H:-}}}`. With no root,
  `ae_mark` and `ae_project` write nothing. `bin/merge-conductor.sh` sets `H`
  before it sources the lib, so the conductor's root is unchanged. The strict
  baseline file for the old path is deleted. The alert-writers ratchet sees the
  same new path, so `_ae_alert`'s fallback (used only when `mc_alert` is not
  loaded) pages through `bin/alert-line.sh` instead of appending to ALERTS.log.

## Why

The tier was the only input to the hand-off, so no operator could hold a
tier-2 APPROVE, and the conductor's self-enqueue lib was named for tier 2.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/tier-retired.bh-4572-test.sh` drives both
extracted hand-off blocks against a scratch harness.

# 2026-10-07 — BH-4980: eject the culprit, don't bisect (shipped in shadow)

Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

When a Mergify batch fails, Mergify splits it and re-tests the halves until it
names a PR (#4958 became #4959-#4962). The merge conductor then ran its own
split too: BH-4550's solo re-run (`bs_batch`) merges each member alone onto the
base and re-runs the failing suites. Both cost CI runs to learn something the
impact map can usually say up front.

`bin/lib/mc-batch-impact.sh` is new. For a PR Mergify did NOT name in a
multi-PR draft (`bej_word` = `bystander`), `bej_reentry_gate`
(`bin/lib/mc-batch-eject.sh`, the `# >>> impact eject (BH-4980)` block) asks it
which members can reach the failing test:

- The failing tests are the draft's failing suites from batch-solo's facts
  (`ok <base> <suites> <members>`). When the logs named jobs, not suites
  (`skip job-only`), it uses the failing checks, mapped to path prefixes by
  `MC_BATCH_IMPACT_CHECK_PATHS`.
- A member reaches a suite when `bin/test-impact.sh select --why` on its files
  names it, always-suites included. A `full` row (infra, a file main's map
  can't place, a file the PR adds) reaches everything.
- **Exactly one member reaches it:** that PR is ejected, with one comment
  naming the test. The others skip the solo re-run and take the existing
  bystander branch at once: main-red freeze, head green, BH-636's once-per-head
  `requeued` mark.
- **Several:** the candidates ask the solo re-run as before, and a pending
  answer holds them. The others go back in at once.
- **None, or anything unknown** (a read failed, a member's dequeue comment is
  not this draft's at its current head, a check is not in the map, a repo other
  than the harness's own, the main-red freeze on): nothing changes.

A PR Mergify named, and a PR it tested alone, are decided exactly as before.

The decision is one per draft, cached in
`$MC_STATE_DIR/batch-impact/<owner_repo>_<draft>` only when every read
succeeded. The members' workers share one computation through a short
`flock -w` on that file. Without that, four workers read the same file lists at
once and raced on `mc_pr_files`' tmp file, and members came back unknown.

`bin/lib/queue-partition.sh` (BH-4979) no longer sources the optional
`risk-tier.sh` at all (main, 98a184589): `risk_tier` is used only when a caller
already loaded it. As a literal source of a file that is not in the tree yet
(#4973), it made `scratch_closure_list` refuse every closure that reaches it,
the conductor's included.

## The two switches, both dark

| switch | where | now | flip |
|---|---|---|---|
| `MC_BATCH_IMPACT` | lane knob, `catalog/lanes.d/merge-conductor.json` | `1` shadow: one `BATCH_IMPACT_<EJECT\|SEVERAL\|NONE\|UNKNOWN>` line per PR head, no decision changed | `2` |
| `batch_failure_attempts` | `config/mergify/repos/cromford.conf` | unset: `.mergify.yml` is unchanged | `0` (renders `batch_max_failure_resolution_attempts: 0` on the default queue only) |

An invalid `MC_BATCH_IMPACT` reads as 0, with one `BATCH_IMPACT_MODE_INVALID`
log line per value.

**Flip order.** Leave the shadow on for a day of real batches, then flip both in
one PR: `bin/harness-ctl.sh set merge-conductor MC_BATCH_IMPACT 2` and
`batch_failure_attempts=0`. That PR carries:

- a real `BATCH_IMPACT_*` excerpt from `logs/merge-conductor.log`;
- the Mergify dequeue comment from one test batch under `attempts: 0`. That
  comment should name nobody, so every member arrives as `bystander`.

Flipping the Mergify key alone is wrong. With the gate in shadow, every member,
the culprit too, would be re-queued as a bystander and end at
`queue-ejected-twice`.

## Tests

`tests/queue-eject-culprit.bh-4980-test.sh`:

- U1-U8: the lib on a fixture map.
- G1-G6, K1: the gate. Every negative decides exactly as mode 0.
- M1-M3: the render.
- E1: the real conductor on a batch of four where only one PR touches
  `worker/`. Exactly one comment, on that PR. The other three are re-queued the
  same tick. No prequeue-gate dispatch.

# The builder gate's snapshot carries a base (BH-8697)

Doc: CI-RUNNERS

## What changed

- `snapshot_tree` in `bin/test-impact-gate.sh` takes an optional base.
  With a base, the snapshot repo has two commits, `base` then `head`, and
  `refs/remotes/origin/main` points at `base`. This is the shape
  `rp_snapshot_build` (`bin/lib/rules-pack-snapshot.sh`) already makes.
- The isolated runner passes the merge-base (`$FORK`). The fresh-main pass
  passes main's tip (`$FM_SHA`). In both, a delta ratchet reads this diff only.
- A base that cannot be archived is rc 125 (could-not-run) for the isolated
  runner and `fresh-main: off` for the fresh pass. The gate never runs the
  suites without a base.

## Why

Before this, the snapshot was one commit with no `origin/main`. Every suite
that sources `tests/lib/ratchet-delta.sh` failed in `rd_base` with "no base to
diff against". BH-8682's claim 4 (`bin/test-impact-gate.sh --base origin/main`)
was red on `tests/scratch-closure-lint.bh-4552-test.sh` for that reason only.

## Test

`tests/test-impact-gate-iso-base.bh-8697-test.sh`, cases B1-B7.

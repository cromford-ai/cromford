# The scratch-closure lint runs at PR time and in the builder gate (BH-4869)

Doc: tests/README.md

## What was wrong

`tests/scratch-closure-lint.bh-4552-test.sh` (BH-4552) ran only in the
merge-queue corpus. The PR `lint` job never ran it, and the builder gate
reached it only as a `source` pick, which its cap or budget could drop. So a
new suite that hand-copied `bin/lib` files passed PR CI and every builder gate,
then went red inside a Mergify batch and took every PR stacked in it down.

On 2026-10-06 no cromford PR merged from 12:25Z to about 15:20Z while
batches kept failing on it: #4680, #4735, #4029 and #4773, with #4600, #4685,
#4732 and #4785 dequeued alongside. #4685 had the same defect on 2026-10-05.

This note supersedes the "not in the always-run set" paragraph of
`docs/notes/2026-10-05-BH-4552-scratch-install-closure.md`.

## What changed

- `catalog/rules-pack.tsv` has a 14th component, `scratch-closure`, a `delta`
  suite row for the lint. The PR `lint` job's `fast always-lints (BH-3860)`
  step already runs `bin/rules-pack.sh` on every ordinary PR, so the lint runs
  there now with no workflow edit and no new required check. The pack also runs
  in `HARNESS_IMPACT_GATE_RUN` on every build phase, fix rounds included, and in
  lead review. A red is the finding line
  `scratch-closure: FAIL: real (delta): <suite>:<line>: hand-copies ...`.
- `bin/test-impact-gate.sh` promotes the lint into its fast tier (first,
  outside the cap) when the diff adds, edits or renames a `tests/*.sh` or
  `tests/mc/*.sh` suite. `--skip-suites` still wins, so a gate that follows the
  rules pack prints `run by the rules pack (outside the cap)` instead of running
  it twice. A checkout without the lint file promotes nothing.
- `prompts/build-discipline.md` has D46, the rule for builders and fix rounds.

The pack's isolated runner builds its snapshot with `origin/main` as the base
and exports `RATCHET_BASE`, so the lint gets a real verdict there. The gate's
own isolated runner does not: its one-commit snapshot has no base, and a delta
ratchet run in it fails with `no base to diff against`. With the pack row, a
builder's gate skips the lint (the pack ran it). Giving the gate's snapshot a
base is a follow-up.

## Commands

    HARNESS_TEST_SANDBOX=1 bin/rules-pack.sh --only scratch-closure --runner local
    RATCHET_BASE=origin/main bash tests/scratch-closure-lint.bh-4552-test.sh
    bin/test-impact-gate.sh --runner plan --base origin/main

Verified by `tests/scratch-closure-pr.bh-4869-test.sh`.

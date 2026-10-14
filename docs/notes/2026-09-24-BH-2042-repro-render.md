# Pre-build repro gate: the plan brief line and the PR-body section render

Doc: repro-gate

## What changed

- `bin/lib/prebuild-repro/render.sh` is no longer a stub. `pr_brief_line`
  prints the plan-prompt line for a `reproduced` record (the detail file folded
  to one line, capped at 2000 characters). `pr_pr_section` prints the PR-body
  section: the reproduced steps, observed result and URL, or one line saying
  why it was not reproduced or was skipped.
- `skip not-bug` and `skip knob-off` print nothing, and no record prints
  nothing, so feature PRs and boxes without the gate keep the same body.
- The rules and the gate-to-output table are in `docs/repro-gate/render.md`.
  The render row of `docs/repro-gate.md` ("nothing") is out of date and that
  page supersedes it.

## Why

BH-2042 (order 3 of #2004): a bug reproduced on prod before the build should
hand its steps to the plan as the acceptance check, and the PR should show the
reviewer what was seen on prod.

`bin/run-build.sh` is unchanged. Its two call sites came with the contract (BH-2039).

## This is an intent review

The risk tier rated this head medium, and the lead asked for an INTENT review of it. Do not read every line of `## Diff`. Check that the change does what its plan says, inside the files its plan names, and that it keeps the iron laws. Read a hunk only when one of the checks below needs it.

Do the checks in this order:

1. The acceptance tests. The plan names them (`## Acceptance tests` in the plan the PR changes under `.harness/specs/`, or the PR body's evidence block). Each one must be a file or a case in `## Diff`. The PR body's self-check, verify evidence or CI output must show each one ran red before the change and green after it. A named test that is not in the diff is a BLOCK. A test with no red evidence is a BLOCK.
2. The planned files. The planned files are the plan's `## Files to touch` and the files the PR body's evidence block names. Compare them with every path in `## Diff`. A path outside them is `[BLOCK] <path>:1: outside the planned files`, unless a `## Files outside the plan` line names it with a reason. List every such path, not only the first one.
3. The iron laws, in the hunks where they can break: a schema change that is not additive, a hardcoded model string, a native browser dialog, a metered API call with no dedup before the spend, and a new table without its indexes and its retention rule. Each one is a BLOCK.
4. The lane. The PR body names the lane or the ticket that built it. A body that names neither is a BLOCK.

If one of these checks needs more than the intent, the plan and the evidence can show you, do not guess. Write `[BLOCK] <path>:<line>: needs a full review: <why>`.

The rules for the verdict and the output format above still apply. A head that passes all four checks gets MERGE, or MERGE-WITH-NOTES when you have notes.

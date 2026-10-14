# Culprit reach uses the batch select; a non-test workflow edit selects (BH-6688)

Doc: MERGE-CONDUCTOR, MERGIFY

## Why

The BH-5373 replay traced 20 members of 16 red multi-member Mergify drafts.
17 of 20 members had a `full` reach (`*`), so the culprit decision was
`several` on all 10 decided drafts and never `eject`. The paths that forced
`*` were `catalog/lanes.d/*`, `catalog/pr-self-check.tsv`,
`catalog/ci-batch-escalate.tsv`, `tests/lib/*` and
`.github/workflows/harness-ci.yml`.

The cause was one flag. `bim_reach` (`bin/lib/mc-batch-impact.sh`) ran
`bin/test-impact.sh select` without `TI_BATCH_SELECT=1`. The select then used
the PR infra list, where every `^catalog/` and `^tests/lib/` path is
`full: infra change`. The batch's own selection (`bin/ci-plan.sh`) already
used the batch rules (BH-6059, BH-6371), so the culprit finder and the batch
disagreed about the same paths.

## What changed

- `bim_reach` runs the select as a batch select. A catalog/ or tests/lib/
  path now reaches the suites the map ties to it. A `full` row still prints
  `*`, and its reason goes to `<files>.full`.
- `_bim_compute` logs two new merge-conductor lines:
  - `BATCH_IMPACT_FULL draft=<d> pr=<n> full: <why> (<path>)`, one for each
    member that reached `*`.
  - `BATCH_IMPACT_REACH draft=<d> full=<k> of <n> members`, one for each
    draft. `<n>` counts only the members whose reach was read.
- New `bin/test-impact-workflow.sh <base> <head> [--root <dir>]`. It names
  the job of every changed line of `.github/workflows/harness-ci.yml`. The
  non-test jobs are `lint`, `determinism`, `prompt-evals` and `ci-timings`,
  plus column-0 `#` comments. Every other line, an unknown job included, is a
  test line. rc 1 = non-test only, rc 0 = a test line, rc 2 = unreadable.
- `bin/ci-plan.sh` (merge-queue batch): a `harness-ci.yml` diff that the
  classifier calls non-test only does not escalate. It selects through the
  map, and the reason says `workflow: non-test jobs only (<jobs>)`. With
  `CI_PLAN_CHANGED_FILE` (no git range) the old answer stays.
- `bin/test-impact.sh`: new env `TI_WORKFLOW_BASE=<sha>`, read only in a batch
  select. When set and the classifier answers rc 1, `harness-ci.yml` selects
  through its map rows instead of `full: infra change`.
- `bin/ci-plan.sh`: with `CI_PLAN_MEMBER_REACH=1` the plan job prints
  `ci-plan: member reach: full <k> of <n> members (#<n> <path>; ...)` and
  writes the same line to the step summary. A failed read prints
  `member reach: unreadable (<why>)`. It is report only. The plan step of
  `.github/workflows/harness-ci.yml` sets it; a shard never does.

## What did not change

- `bin/run-tests-in-docker.sh` and the other runners stay `full`.
- The culprit finder has file names only, not the diff, so a member that
  changes `harness-ci.yml` still reaches `*` there.
- The PR select (`ci-select`) and the builder gate do not set
  `TI_BATCH_SELECT`, so their answers do not change.

## Re-measure after merge

1. Read the merge-conductor log on the hub: `grep BATCH_IMPACT_REACH`.
2. Read the `ci-plan: member reach:` line in the plan job log of each
   merge-queue batch.
3. Compare `full=<k> of <n>` with the 17 of 20 (85%) baseline.

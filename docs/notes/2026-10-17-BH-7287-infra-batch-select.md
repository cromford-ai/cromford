# A test-infra path in a merge-queue batch runs its own suites and 40 canaries, not the corpus (BH-7287, wave 1 of BH-7033)

Doc: MERGIFY

## Why

`catalog/ci-batch-escalate.tsv` had 24 escalate rows. 21 of them were the
files the selection runs on: the planner, the selector, the tier step, the
runners, their libs and catalogs, and `tests/lib/scratch.sh`. A batch that
touched one of them ran the whole corpus (2,507 suites on this tree, 8
shards), even when the change was one comment line.

## What changed

- `catalog/ci-batch-escalate.tsv`: a new kind, `infra`. The 21 rows changed
  from `escalate` to `infra`. Three escalate rows are left: `.github/` (a
  top-level workflow is still an allow row, BH-6876), `.mergify.yml` and
  `catalog/ci-batch-escalate.tsv`.
- `bin/lib/ci-batch-escalate.sh`: new `cbe_infra <path>` (rc 0 when an infra
  row matches and no allow row does) and `cbe_deletes_row <diff-file>`.
- `bin/ci-plan.sh`: a batch whose OWN diff has an infra path plans
  `mode=infra`. The list is the normal selection of the other paths (always
  set included), plus the self and reads suites of each infra path
  (`bin/test-impact.sh select --why --map-only`), plus the 40 suites of the
  new `catalog/ci-infra-canary.txt`. The tier step, the regression union, the
  quarantine and suite reuse then run on that list. spa and worker stay 1.
- A diff to the rules file has three outcomes: add-only selects (BH-6371); a
  delete runs the corpus, `selection input: catalog/ci-batch-escalate.tsv`;
  any other readable diff is an infra path. A delete is a removed row whose
  `pattern<TAB>kind` is not added back (a kind change counts), an added allow
  row, a malformed row, an empty diff or an unreadable one.
- `bin/test-impact.sh`: `ti_inputs_infra` and `ti_pr_catalog` ask
  `cbe_reason || cbe_infra`, so the `@infra` fingerprint set and the plain-PR
  select answer do not change.

## Fail-closed rules

- An escalate row beats an infra row. `CI_FULL_TRIGGERS=+tests/lib/scratch.sh`
  (the ci-plan-settings row) puts one path back on the corpus with no PR.
- A full answer on the batch's other paths (unmapped, unknown reach) is full.
- A canary list that cannot be read, is empty, or has a line that is not a
  present `tests/<name>.sh` path (no glob, no `..`) runs the corpus,
  `escalation=infra canary list unreadable (<why>)`.
- An infra select that fails is rc 2 and writes no shard count.

## Size

A `tests/lib/scratch.sh`-only batch plans 117 suites on 1 shard: 5 self/reads,
the 40 canaries and the 77-suite always set (the 19 rows of
`catalog/test-impact-always.txt` plus the map's `*` rows). Before, it planned
2,507.

## Tests

`tests/ci-batch-escalate-select.bh-7287-test.sh` (the ticket names
`...bh-7033-1-test.sh`; the file uses this ticket's key). Six suites pinned the
old escalate rows and now assert `mode=infra`: bh-6059, bh-4968, bh-6838,
bh-6876, bh-4969 and bh-6371.

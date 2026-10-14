# A merge-queue batch runs its impact set, not the whole corpus (BH-4968, C0 of BH-4964)

Doc: MERGIFY, COST

## What changed

- `bin/ci-plan.sh`, the `mergify/merge-queue/*` case only. The batch's changed
  list (`git diff --no-renames --name-only TI_BASE HEAD`, or
  `CI_PLAN_CHANGED_FILE`) is built once and the tier step reuses it. The batch
  runs `bin/test-impact.sh select --changed <list>`, mode `batch-selected`,
  and the tier/quarantine step runs after it exactly as before.
- It escalates to the full corpus (the old `ci-select` call), first match wins:
  - no `TI_BASE` -> `no batch base`
  - the `full` label -> `the 'full' label`
  - the changed list cannot be read, or the diff fails -> `the changed list
    could not be read` / `cannot diff the batch base <sha8>`
  - a changed path `catalog/ci-batch-escalate.tsv` names -> `selection input:
    <path>`; if the rules lib cannot be sourced -> `the escalation rules could
    not be read`
  - an empty diff -> `the batch diff is empty`
  - test-impact's own full answer: unknown reach -> `unmapped: <p>`, infra ->
    `selection input: <p>`, anything else kept as it said it
  - a selection of every suite (judged before tiering) -> `the selection is
    every suite`
- A failed `select`, or one with no `impact:` line, is rc 2 with no `n=`.
- New output `escalation` (`-` when the batch did not escalate and on every
  non-batch path). A batch also prints `::notice title=ci-plan::mode=… count=…
  total=… n=… reason=…` and appends the summary and `escalation:` lines to
  `GITHUB_STEP_SUMMARY`.
- New `catalog/ci-batch-escalate.tsv` (`pattern<TAB>kind<TAB>why`; `escalate` /
  `allow`, other kinds skipped for sibling readers) and
  `bin/lib/ci-batch-escalate.sh` (`cbe_reason <path>`). Unreadable rules, or no
  escalate row, escalate every batch.
- `.github/workflows/harness-ci.yml`: the plan job exposes `escalation`; the
  `fast always-lints` and `share-mirror leakcheck pre-check` lint steps now also
  run on a batch draft, since a batch no longer runs the whole corpus.

## Planning probes (real test-impact, 1710 suites)

- `console-ui/src/screens/Jobs.js` -> 111 of 1710, one shard.
- `docs/x.md` -> the always set plus doc readers (56).
- `zz-unmapped-bh4964/x.sh` -> unknown reach -> `unmapped:`.
- A brand-new `bin/*.sh` is NOT unknown reach: the whole-`bin/` scanner suites
  reach it (267 selected). It runs batch-selected.

## Interactions

- `bin/lib/mc-foreign-red.sh` `_fr_batch_ran` requires `mode=full`, so a green
  `batch-selected` batch counts as "not ran" for foreign-red attribution. That
  is the conservative direction; a later slice can teach it the selection.
- The shard re-plan (`--expect-n`) reads the same env and diff, so it agrees.
- Out of this slice: a member PR's `full` label and SPA/worker rows (siblings
  of BH-4964).

# The batch-escalation rules read a fragment folder (BH-8608, slice C0)

Doc: MERGIFY, TESTING

## What changed

- `bin/lib/ci-batch-escalate.sh` composes the rules from
  `catalog/ci-batch-escalate.tsv` and then every
  `catalog/ci-batch-escalate.d/*.tsv`, in `LC_ALL=C` name order (`cbe_rules`).
  `cbe_reason`, `cbe_affects` and `cbe_infra` read the composed rules.
  `CI_BATCH_ESCALATE_TSV` still replaces all the sources with one file.
- A source that cannot be read (a dangling fragment, a missing old file)
  fails closed, as an unreadable old file did.
- `bin/ci-plan.sh` judges the old file and the fragments as one diff
  (`cbe_rules_diff`). An added fragment with only escalate, spa or worker rows
  selects through the map, the same as an appended row. A row moved between
  sources is infra, not a delete. `cbe_add_only` and `cbe_deletes_row` accept
  the `new file mode`, `deleted file mode`, `old mode` and `new mode` lines.
- `bin/test-impact.sh inputs` (the suite fingerprint) and
  `bin/ci-plan-split-replay.sh` read the composed rules.
- New lint `cbe_check`. `tests/ci-batch-escalate-fragments.bh-8608-test.sh`
  runs it on the tree.
- The X1/X2 failure text of `tests/cross-tree-rows.bh-8573-test.sh` and
  `tests/ci-plan-spa-worker.bh-4969-test.sh` names
  `catalog/ci-batch-escalate.d/<TICKET>.tsv`.

## Why

Every PR that added a row appended it to the end of one file. Parallel PRs
conflicted on the same last lines: #7653, #8550 and #8511 (twice) on
2026-10-27. A new row now goes in a new file, so two PRs add two files.

## What is not in this slice

Slice C1 moves the 92 rows of `catalog/ci-batch-escalate.tsv` into fragments,
deletes the old file and adds a lint that refuses it back in git.

## How to check

```bash
( . bin/lib/ci-batch-escalate.sh && cbe_check )
HARNESS_TEST_SANDBOX=1 bash tests/ci-batch-escalate-fragments.bh-8608-test.sh
```

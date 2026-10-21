# BH-7536: harness-ci.yml becomes a render of config/harness-ci/

Doc: config/harness-ci/README.md

BH-7536 is slice 1 of 5 of BH-7452. `.github/workflows/harness-ci.yml` was
one 1879-line file that most CI changes edit, so parallel PRs conflicted on it.

## What changed

- `config/harness-ci/` holds the workflow as 16 fragments: four top-level
  blocks and one `NNN-<job>/000-job.yml` per job (12 jobs). The split is byte
  for byte: the render of the fragments `cmp`s equal to the workflow before
  this change.
- `bin/render-ci-workflow.sh` renders them. Modes: print (default), `--write`,
  `--check`, plus `--root <dir>`. Exit codes follow
  `bin/lib/render-fragments.sh`: 0 rendered or clean, 1 drift, 2 cannot render
  (and any render failure under `--check`), 3 a refused fragment.
- The `lint` job has one new step after `lane renders generate and their
  sources validate`: `the workflow render matches its fragments (BH-7452)`,
  which runs `bin/render-ci-workflow.sh --check`. It has no reuse gate.

## Rule

Edit a fragment, run `bin/render-ci-workflow.sh --write`, commit both. A hand
edit of the workflow is drift, and the `lint` job is red on it.

## Not in this slice

Per-step files, the merge conductor regen row and `catalog/list-files.tsv`
are siblings BH-7452.2 to .5.

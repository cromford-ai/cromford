# The config-inventory renders leave git (BH-5518, slice C0)

Doc: config-inventory

## What changed

`bin/config-inventory.sh` writes `inventory.json`, `index.html`,
`deployment.json` and `deployment.md` into `docs/config-inventory/`. All four
were tracked, and so was `registry-drift.tsv` (the hand-run
`tests/config-literal-lint.sh --drift` snapshot). Now all five paths are in
`.gitignore` and out of the tree.

- `bin/config-inventory.sh --check` is new. It renders the tree twice into
  temp dirs and writes nothing under the repo. rc 1: the two renders differ, a
  path under `docs/config-inventory/` is tracked, or `deployment.md` records an
  un-allowlisted literal. rc 2: it could not run (no python3, no git, the
  generator failed).
- CI's "the derived docs generate and their gates pass" step runs
  `bin/config-inventory.sh`, then `bin/config-inventory.sh --check`.
- `tests/no-hardcoded-deployment.bh-4080-test.sh` R1 no longer compares a
  render with committed bytes. It runs `--check` and asserts nothing is tracked.
- `tests/config-inventory.bh-1511-test.sh` section 8 compares two renders and
  is a hard FAIL (it was a WARN against the committed file).
- `tests/config-inventory.bh-1530-test.sh` section 7 reads a fresh render.

- `bin/config-inventory.py`: a new classifier rule, `stage-module-assigned`.
  Section 7 of bh-1530 now reads a fresh render, and that render showed
  `REPRO_RC` as `TEST_HOOK`. `bin/lib/rb/execute.sh` assigns it and
  `bin/lib/rb/pr.sh` reads it. Both are stage modules that `bin/run-build.sh`
  sources into one shell (BH-478), so BH-1530's same-file rule missed it. The
  committed inventory was rendered at `0dd962ac`, before the split, and hid
  this. Now a name that a `bin/lib/rb/` or `bin/lib/rt/` module assigns, and a
  file of the same driver reads, is `PLUMBING`, not `TEST_HOOK`. It moves 10
  names (`BOARD_SEC CLOSES_LINE INTENT_RC RB_CTX_REEXEC RDIRS REPRO_RC
  SIZE_NOTE STACK_NOTE TAMPER_RC TICK_SCOPE`). No `CONFIG` name moves, and the
  proposed slices are byte-identical.

## Why

Every PR that re-rendered touched the same files, so two such PRs always
conflicted (at least on `generated_at_commit`). A merge batch of two PRs that
each rendered alone committed a `deployment.md` that was neither side's
render, and R1 failed batches #5426 and #5427.

## How to read the inventory now

Run `bin/config-inventory.sh`, then open `docs/config-inventory/index.html`.

## Not in this slice

Durations to D1 and the `worker/jobs/schema.sql` seed blocks stay on #5518.

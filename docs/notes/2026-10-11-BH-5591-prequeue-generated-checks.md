# Pre-queue invariants: render-doc-sections and the jobs-worker schema tests (BH-5591)

Doc: MERGE-CONDUCTOR

## Why

Merge batch #5584 (2026-10-08 17:18Z, 7 PRs) went red in under 2 minutes on two
whole-tree checks. Neither check was in `catalog/prequeue-invariants.tsv`, so the
pre-queue gate passed each head alone:

1. `bin/render-doc-sections.sh --check`. #5297 split `docs/PR-OWNERSHIP.md` into
   `docs/PR-OWNERSHIP.d/`. Main then changed one row of the doc, so the
   fragments were stale on the merged tree.
2. Three jobs-worker schema tests. #4744 and #5287 each added to
   `worker/jobs/schema.sql`. Each passed alone. The combination failed.

## What changed

Two `cmd` rows at the end of `catalog/prequeue-invariants.tsv`:

| id | argv | budget_s |
|---|---|---|
| `render-doc-sections` | `bin/render-doc-sections.sh --check` | 2 |
| `worker-jobs-schema` | `bin/prequeue-worker-schema.sh` + the three test files | 15 |

The three files are `worker/jobs/test/machines-schema.bh-1054.test.js`,
`worker/jobs/test/model-routes.bh-1510.test.js` and
`worker/jobs/test/schema-deploy-queue.bh-1026.test.js`. They are catalog argv,
so a PR cannot drop one: the gate reads the catalog from main.

`bin/prequeue-worker-schema.sh` is new. A `cmd` row never goes through a shell
and its argv[0] must be a file in the tree, so `node --test` cannot be a row by
itself. The wrapper:

1. Renders `catalog/lanes.json` if it is absent or stale (the worker imports it).
2. Runs `npm ci --no-audit --no-fund` in `worker/jobs`, the same install as the
   CI job "Jobs worker — routes + schema".
3. Runs `node --test --test-reporter=tap <files>` in `worker/jobs`.
4. Prints `FAIL: worker-schema: <name>` for each top-level `not ok` line.
5. Applies the CI skip guard: node rc 0 is green only with `# pass` > 0 and
   `# skipped` = 0. A skip is never green.

Exit codes: 0 green, 1 red, 2 a bad argument list.

## The DRIFT fail text

`bin/prequeue-invariants.sh` writes `fail/<id>.txt` from the first 8 `^FAIL`
lines, else the last 8 lines. `render-doc-sections.sh --check` prints
`DRIFT <doc>` and then up to 25 diff lines, with no `^FAIL` line. On a large
drift the last 8 lines dropped the doc name. Now a row with no `^FAIL` line that
prints a `DRIFT <path>` line reports from that line on (8 lines max). A row with
`^FAIL` lines is unchanged. A row with neither still reports its last 8 lines.

## Measured

Three runs of both rows through the real runner on the build box (node v22.23.2,
warm npm cache), `bash bin/prequeue-invariants.sh --run --catalog <(both rows) --out DIR`:

| run | render-doc-sections | worker-jobs-schema | wall |
|---|---|---|---|
| 1 | 0 s | 3 s | 3 s |
| 2 | 0 s | 4 s | 4 s |
| 3 | 0 s | 2 s | 2 s |

The worker row reported `pass=28 skipped=0` each time. The plan measured
`npm ci` at 8.3 s on a cold cache, so the budget is 15 s. A budget is a report,
never a kill. There is no durations row: `catalog/ci-suite-durations.tsv` is
git-ignored since BH-5518.

## Operating it

- Turn a row off: the settings row `conf.prequeue-invariants.<id>=off`
  (BH-5440). For example, set `conf.prequeue-invariants.worker-jobs-schema=off`
  when the npm registry is down: a failed `npm ci` is a red row.
- Rebudget a row: `conf.prequeue-invariants.<id>=<seconds>`.
- A new sectioned doc (a second `docs/<x>.d/`): the default argv checks only
  `docs/PR-OWNERSHIP.md`. Add the new doc path to the `render-doc-sections` argv.

Tests: `tests/prequeue-invariants.bh-5591-test.sh`, and the C1 pins in
`tests/prequeue-invariants.bh-5429-test.sh`.

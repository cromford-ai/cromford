# sql-command-injection stops parking constant and ?N-placeholder interpolations (BH-4501)

Doc: checks/README.md

## What was wrong

Shape 2 of `checks/sql-command-injection/check.sh` flagged every added line
that opens a SQL template literal and contains `${`. It could not tell a bind
placeholder or a module constant from a request value. That parked
#4044 (`usage.js:72`), #4142 (`initiatives.js:146`) and #4232
(`lead-protected-paths.js:42`, `:58`, `:79`), and each hit cost a
blocked-resolver adjudication after every push.

## What changed

- `check.sh` now reads the whole added-line stream before it decides. A shape-2
  line is reported unless every `${...}` on it is a module const, a ternary,
  `||` or `+` of safe parts, a `?${binds.length}` placeholder, or a
  `.join()` of a local array that is only ever pushed safe values. The exact
  rules are in `checks/sql-command-injection/WHY.md`.
- Shapes 1 and 3, the output format, and the family suffix are unchanged.
- An awk crash now exits 2, so the runner prints `CHECK-ERROR`. Before, it
  printed nothing and the check read as clean.
- On main@0ad5fe5's `worker/`, the hit count drops from 91 to 74. All 17 removed
  hits are pinned and were read by hand. Each one is a column-0 literal const
  or a `where` array pushed only literal placeholder strings. No new hit
  appears.

## Fixtures

`checks/sql-command-injection/fixtures/` gains these files:

- `green-*.diff`: one per accepted shape.
- `red-*.diff`: 17 near misses that must still flag.
- `replay-*.diff`: the three parked PRs' files.
- `whole-file-0ad5fe5-worker.diff`: the nine files whose hits changed.
- `pre-bh4501-check.sh.txt`: a frozen copy of the old check, used for the
  before/after comparisons.

`tests/sql-command-injection-allowlist.bh-4501-test.sh` drives all of them
through `bin/checks-run.sh`.

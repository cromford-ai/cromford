# The conductor's ownership map is fragments, not one shared file

Doc: MERGE-CONDUCTOR

## What changed

`tests/mc/expected-map.tsv` is gone. The same 356 rows (296 `origin=lib`, 60
`origin=driver`) now live in `tests/mc/expected-map.d/00-lib.tsv` and
`tests/mc/expected-map.d/00-driver.tsv`, and a change that adds a conductor
function writes its OWN fragment, `tests/mc/expected-map.d/<TICKET-KEY>.tsv`.
`tests/lib/mc-expected-map.sh` (`mc_expected_map <dir> <out>`) assembles the
union for the three suites that judge the split — `tests/mc-split-layout-test.sh`,
`tests/mc/lib-complete-test.sh`, `tests/mc/driver-complete-test.sh` — and every
assertion in them runs unchanged against it.

## Why

Between 2026-09-21 and 2026-09-24 the file was touched by 21 commits, 11 of
them rebases, review rounds or lead fixes. Every PR that added a function
appended a row beside its neighbours and a sentence to the file's one-line
header comment, so ANY two such PRs conflicted on that line: a DIRTY PR, or a
Mergify batch that could not be built, on a hunk neither ticket was about. The
rows are a set (no reader depends on their order), so one file per change
removes the shared hunk without changing what is checked.

## What the assembler refuses

A row that is not three tab-separated fields, a module outside
`log locks classify queue rebase settle`, an origin other than `lib|driver`, a
function claimed by two rows (in any two fragments), and an empty or missing
directory. Each refusal names `file:line`, and each consumer reports it as a
finding. `tests/mc/expected-map-fragments-test.sh` pins all of that, and that
the single file stays retired.

## Adding a function

Write `tests/mc/expected-map.d/BH-1234.tsv` with your rows and, if you like, a
`#` comment saying where they sit and why. Do not edit `00-lib.tsv` or
`00-driver.tsv` — the driver set is closed at 60 rows.

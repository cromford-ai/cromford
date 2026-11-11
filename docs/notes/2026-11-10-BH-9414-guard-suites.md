# BH-9414 slice C0: the pre-push suite run adds the always-run guard suites

SLICE: C0 of #9414 (Fix 1, acceptance 2).

## What changed

`HARNESS_SUITE_RUN` (`bin/lib/rb/gates.sh`) runs a project's unit suite before a
build pushes. On a selected run it ran only the files `bin/lib/test-select.sh`
picked. That selector reads `tests/static-guards.txt` and `tests/static-guards/`,
but project-6 declares its always-run guards in `scripts/ci/lane-rules.json`
`alwaysSuites` (TK-3641). So the box never ran the tenancy guard that CI ran on
project-6 PR #3662.

Now a selected run also gets the guard list from `bin/lib/verify-guards.sh`:

1. Each entry of the knob `VERIFY_GUARD_SOURCES`, in order, read at HEAD:
   - `<file>`: a text file, one path or glob per line, `#` comments.
   - `<file>#<key>`: a JSON file; `<key>` is an array of path strings. Only that
     key is read (`alwaysFull` is never read).
2. Every file under `tests/static-guards/` at HEAD.

A path is dropped when it is empty, starts with `-` or `/`, has a `..` part,
has CR or LF, has an `e2e` path part (the box never runs E2E), or is not a
file in the HEAD tree.

## Record line

The outfile has a new second line:

- `HARNESS_GUARDS: <n> guard suite(s) in the run` (selected run; the guards are in npm argv).
- `HARNESS_GUARDS: <n> guard suite(s), in the full run` (a full run already runs them).
- `HARNESS_GUARDS: none listed (<why>)` (the list cannot be used).

When the list cannot be used (bad JSON, a key that is not an array of strings,
more paths than the cap), a selected run becomes FULL and `HARNESS_SUITE:`
says `full (guard list unreadable: ...)` or `full (guard list over the cap: ...)`.
A bad list never narrows a run. With no `verify-guards.sh` in the harness, the
run is as before and has no `HARNESS_GUARDS:` line.

## Knobs

Registry fragment `catalog/lanes.d/_lib.verify-guards.json` (lib `verify-guards`).
The defaults live only there.

| Knob | Row | Default |
|---|---|---|
| `VERIFY_GUARD_SOURCES` | `lib.verify-guards.verify_guard_sources`, or `lib.verify-guards.<project>.verify_guard_sources` | `tests/static-guards.txt,scripts/ci/lane-rules.json#alwaysSuites` |
| `VERIFY_GUARD_MAX` | `lib.verify-guards.verify_guard_max`, or `lib.verify-guards.<project>.verify_guard_max` | `200` |

Order: the project row, then the fleet row, then the env, then the default.

## Known limit (A6)

A guard path outside the paths the repo's npm script includes (for example
outside vitest `include`) can make vitest answer "No test files found". The
selector's source (d) has the same behavior today for `tests/static-guards.txt`.

## Slices left

- C1: Fix 3, re-run the guard suites that changed on `origin/main` after the
  base (fresh main). It reads `vg_list` from this slice. Acceptance 3.
- C2: Fix 4, a fix round reproduces the CI failure before it pushes.
  Acceptance 4 and 5.

Test: `tests/verify-guards.bh-9414-test.sh`.

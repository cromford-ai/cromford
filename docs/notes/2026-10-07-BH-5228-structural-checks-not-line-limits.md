# Source files are held to structural checks, not line limits (BH-5228)

Doc: MERGE-CONDUCTOR

## The rule

We do not put size limits on source files. A line count is a proxy: it fails an
honest change that adds one line and passes a regression that fits under the
number. It also makes code worse, because builders chain unrelated statements
onto one line to fit (the merge-conductor shim had grown `...; command -v ...`
chains for exactly that reason). Each limit is replaced by the structural fact
it was standing in for, and each check is driven over fixtures in its own suite
so a green is never vacuous.

Caps on OUTPUT size (diff previews, quoted excerpts, payload bytes, log lines)
are behaviour, not code shape. They stay.

## What replaced what

| Was | Now | Suite |
| --- | --- | --- |
| `bin/lib/merge-conductor-lib.sh` <= 20 lines | every line is shim grammar: an assignment, a `command -v <fn> \|\| { [ -r p ] && . p; }` guard, a source line, the module `for` loop, or `unset`. No function, no `if`/`case`, one statement per line. Checks 2-4 (map completeness, the shim defines nothing) are unchanged. | `tests/mc/lib-complete-test.sh` |
| `bin/run-build.sh` <= 400 lines | the driver carries no stage body: no stage function defined, no stage module's `# >>> ` marker reopened, no run of 5 consecutive module code lines repeated (`tests/lib/driver-shape.sh`) | `tests/rb-split-layout.bh-572-test.sh` check 3 |
| `bin/run-triage.sh` <= 380 lines | the same driver-shape check over `bin/lib/rt/` | `tests/rt-split-layout-test.sh` A6 |
| `bin/lib/gh-rest.sh` <= 113 code lines | its functions are exactly the contract set (read at runtime), and every top-level line is a comment, the re-source guard, an assignment or a guarded sibling source | `tests/gh-rest-lib-test.sh` section 9 |

The driver check's S1 is an allowlist: each split-layout suite names the exact
helpers its driver may define (`RB_DRIVER_FNS`, `RT_DRIVER_FNS`), so a stage
body pasted back under a fresh unprefixed name fails, and adding a driver
helper is a one-word edit to the suite's list. The shim grammar allows no
command substitution in an assignment except the exact `MC_LIB_DIR` line, and
the gh-rest shape check refuses `<(…)`/`>(…)` at top level.

## The merge-conductor siblings

The shim sources each sibling lib with one guarded line, the file name literal
on that line. A first cut put them in two heredoc lists the shim looped over
(`MC_SIBLINGS_HERE`, `MC_SIBLINGS_HARNESS`). Batch #5829 dequeued it: suites
install the shim with `scratch_install_closure`, whose `scratch_closure_list`
reads sourced file names statically, and a name inside a heredoc is invisible
to it. The scratch copy got 3 of 13 siblings, so `tests/slice-closeout.bh-4662`
(no `issue-state-lib.sh`) and `tests/merge-path-stall.bh-4918` (no
`block-gate.sh`) failed. The grammar check already allows guarded source lines,
so the loops were removed. `tests/mc/lib-complete-test.sh` check 5 now fails if
any sibling the shim sources is missing from its closure.

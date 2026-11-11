# Fresh-main guards: the pre-PR gate runs the guards main changed after the build's base (BH-9471)

Doc: RUN-BUILD-GRAPH, TESTING

## Why

project-6 PR #3608 was built on a base from before TK-3485 added a
clock-relative guard to main. The build's verify never ran that guard. CI ran
it on the merge with main and went red. This is #9285 Fix 3 and acceptance 3,
delivered as slice C1 of #9414.

## What changed

1. `bin/lib/verify-run.sh` (new). `vr_run_files <dir> <out> <budget_s> <file>...`
   runs named test files once: `npm run test:unit` (else `test`) with the files
   after `--`, or `bash <file>` when every file is `.sh`. The run gets CI's
   locale (`ce_suite_record`, `bin/lib/ci-env.sh`), the throwaway Postgres when
   `POOL_TEST_POSTGRES` is 1 (`bin/lib/pg-test.sh`) and a timeout. It prints
   `green`, `red` or `could-not-run`. A run past the budget is `could-not-run`,
   never green.
2. `bin/lib/fresh-main-guards.sh` (new). `fmg_run <wt> <base> <out>` fetches
   origin's base into the private ref `refs/harness/fmg/<pid>`. It keeps each
   guard main declares at that ref (`vg_list`, slice C0) that is in
   `git diff --name-only $(git merge-base HEAD <ref>) <ref>`. It runs those
   guards on the tree of `git merge-tree --write-tree HEAD <ref>` in a temp
   worktree. Every return deletes the ref and the worktree. The five words:
   - `clean` (rc 0): no guard changed on main, or each changed guard is green.
   - `red` (rc 1): a changed guard is red.
   - `could-not-run` (rc 2): bad base name, budget spent, fetch failed, no
     merge-base, guard list unreadable or over its cap, merge conflict, or a
     guard that could not run (locale, Postgres, runner, timeout).
   - `skipped` (rc 3): the repo ships `bin/test-impact-gate.sh`. Its
     `--fresh-main` run (BH-6459) already covers this (cromford itself).
   - `off` (rc 4): the knob is 0. Nothing is fetched.
3. `bin/lib/prepr-gate.sh`. `prepr_scan` calls `fmg_run` last, after ci-local.
   It also calls it on the "repo ships no pre-PR gates" path, which every
   product repo takes. There a red guard makes the scan rc 1 in place of 3.
   A red guard is the in-diff finding
   `FRESH-MAIN-GUARD <file>: <first FAIL or Error line>` and shares the one
   pre-PR fix turn. The brief tells the fix turn never to edit main's guard.
   `prepr-scan.txt` gets `fresh-main-guards: <word>`, `prepr.txt` gets
   `fmg=<word>`, and `pipeline.log` gets `PREPR <label>fresh-main-guards=<word> red=<n>`.
   On a product repo the re-scan after the fix turn is clean only when the
   guards said `clean`. Any other word leaves the fix unverified, and the
   state is red.

## A red guard does not stop the build

A `FRESH-MAIN-GUARD` line still red after the fix turn makes `PREPR_STATE=red`.
The PR opens with the "Pre-PR gate: unresolved" section and ` | prepr=red`.
It does NOT make `PREPR_LINT_STATE` red, so `rules_pack_block` does not stop
the build. The guard is main's code on a merge tree, and CI runs the same
merge. A box fault is `could-not-run`, which refuses nothing.

## Knob and budget

- `FRESH_MAIN_GUARDS` (int 0..1, default 1), fragment
  `catalog/lanes.d/_lib.fresh-main-guards.json`. Rows:
  `lib.fresh-main-guards.fresh_main_guards` and
  `lib.fresh-main-guards.<project>.fresh_main_guards`. Rollback: set the row
  to 0. No deploy is necessary.
- Budget: the existing `CI_LOCAL_BUDGET_S` (`cl_budget`, default 900 s) minus
  the seconds ci-local used in this scan. No new timeout knob.

## Known limit

A guard path that the repo's npm test script does not include can make vitest
answer "No test files found" (rc 1, red). The C0 suite run has the same
behavior for the same lists. It is a PR-body note, not handled here.

## Slices left

Slices left: C2 (#9472), reproduce before a fix push.

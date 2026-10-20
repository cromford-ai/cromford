# The committed plan and the diff must name the same files (BH-7273)

Doc: TESTING

## Why

In 15 lead-review BLOCKs in 14 days, plan.md said that tasks, files or path classes
changed, and the diff did not back it (#7130, #6620, #6519, #6023). D5 and D30 are rules
the builder reads, and the builder broke them again. A mechanical comparison stops the
most common form.

## What changed

`bin/lib/plan-diff-bind.sh` is a new check. It is the `plan-diff-bind` row in
`catalog/rules-pack.tsv` (shape `delta`, kind `cmd`). So it runs:

- before the push, in `bin/prepush-gate.sh` (component `rules-pack`). A red gets the one
  existing fix round. If it is still red, the push stops (`REVIEW_BLOCKED prepush-gate`),
  so the PR does not open or update.
- in CI, in the `fast always-lints` step, on every ordinary PR and merge-queue draft.

It reads the one `.harness/specs/<KEY>/plan.md` that the diff adds or changes, at HEAD.
It compares it with `git diff --name-only <merge-base> HEAD`. A diff with no such plan,
or with two and more (a merge-queue batch, a stack), is skipped with rc 0 and a stderr
note.

## The four findings

Each finding is one stdout line: `<kind> <path> <plan-path>[:<line>] — <what to fix>`.
The rules pack prefixes `plan-diff-bind: `. rc 1 on any finding, rc 2 when it cannot run
(the pack reads that as could-not-run).

- `planned-not-changed`: an entry line of `## Files to touch` (a bullet, a numbered item
  or a table row) names a path in its first three words, and the diff does not change
  it. Only the first path token of the line counts. A glob (`<stamp>` or `*`) needs one
  changed path that matches it. A dir scope (`docs/notes/`) needs one changed path under
  it.
- `changed-not-planned`: the diff changes a path under `bin/`, `worker/`, `tests/` or
  `catalog/`, and no path token anywhere in the plan names it. Tokens in
  `## Sibling claims (not touched)` and `## Verify (run, not edited)` do not name. A
  broad dir scope (`bin/lib/`) or a broad glob (`bin/*.sh`) does not name either.
- `class-claim`: a sentence says no path under a dir changes (the shape "no path under
  `<dir>/` changes", "nothing in `<dir>/` is edited"), and the diff changes a path under
  that dir. A quoted example, a sentence with if, when, unless or whether before the
  claim, and a sentence with except, other than, besides, apart from or but after it are
  not claims.
- `case-missing`: a Files-to-touch entry for a changed `tests/` file says new or add and
  names a case ID (`R7`, a range `R1-R6`, `C1 to C3`, `K1..K2`). The ID is not a word in
  the file at HEAD. `D<n>` and an ID that starts a plan heading (`### T4.`) are not case
  IDs. A range over 60 is not judged.

## How a builder fixes a finding

1. If the plan is wrong, edit `.harness/specs/<KEY>/plan.md` and commit it.
2. If the diff is wrong, change the diff.
3. If a Files-to-touch line names a file the build only runs, mark the line
   `verify-only:`. A line with `only if`, `if needed`, `if required` or `optional` is
   exempt too.

A resume can rewrite `.harness/specs/<KEY>/plan.md` from the build dir plan
(`rb_spec_artifact`). So a fix in the committed plan alone can be lost on a resume. Fix the
build dir plan as well.

## Knobs and the off path

- `PLAN_DIFF_BIND_IGNORE`: a comma list of globs the diff side drops. The default is
  `tests/mc/expected-map.d/*`, the generated path the `plan-files` rule ignores. An empty
  value drops nothing.
- Off: the settings row `prepush.gate_mode` (`warn` or `off`) turns the builder side down.
  Remove the catalog row to turn the CI side off.

## Blind spots

- Task-step prose is not read for `planned-not-changed`.
- `class-claim` knows only the "no path under `<dir>/` changes" shape.
- A path named anywhere outside the two skipped sections counts as named, a mention in
  prose included.
- A path token needs its first segment to be a top-level entry of the repo, so a typo in
  that segment is not judged.

# The PR evidence file list is this build's own diff (BH-7114)

Doc: RUN-BUILD-GRAPH

## Why

Three writers filled `$BUILD/changed-files.txt` with
`git diff --name-only "$BASE"...HEAD`. `$BASE` is the LOCAL branch name. All
worktrees of a hub checkout share that ref, and it moves once at build start.
The pre-PR block rebases onto `origin/$BASE`. After a sibling PR merges,
`main...HEAD` takes the merge base with the old local `main`. The sibling's
files then appear in this build's list, its tier pattern and its `| files |`
row. project-6 #908 listed 28 files for a 17-file diff, and #3049 listed 34
for a 4-file diff.

## What changed

- New lib `bin/lib/diff-base.sh`:
  - `diff_base_ref <base>` prints `origin/<base>` when that ref resolves, else
    `<base>`. This is the rule `SCOPE_BASE` and `WHAT_BASE` already use.
  - `diff_changed_files <base>` prints `git diff --name-only <merge-base> HEAD`.
    With no merge base it runs the old three-dot line and returns git's rc.
- `bin/lib/rb/pr.sh` (`CHANGED`, so the tier pattern and the PR-open
  `changed-files.txt`), `bin/lib/rb/result.sh` (evidence settle) and
  `bin/lib/rb/execute.sh` (semgrep input) use `diff_changed_files`.
- The claim scorer's staging base in `bin/lib/rb/result.sh` and
  `bin/lib/rb/review.sh` is `diff_base_ref "$BASE"`. A sibling's merged edit
  to a named test no longer reads as this build's staging.
- A box with no lib (mid-sync) keeps the old lines.

## Test

`tests/evidence-files-base.bh-7114-test.sh` runs the settle blocks of two
builds at once on one shared origin and local `main`.

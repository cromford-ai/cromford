# BH-4662 (BH-4656 part 5): a sliced plan never closes its parent, and "children own the rest" only when a child exists

Doc: VERIFICATION-MAP

## Why

A plan whose line was `SLICE: C0 of #4477` still opened its PR with
`Closes #4477`, because `_prepr_parents` only rewrote `Part of #N` parents, and
GitHub's keyword close shut the master at merge (#4500 / #4477). And the slice
close-out posted "children own the rest" and stripped `ai-build` on
`slice:plan` and `slice:no-keyword` without reading whether a child existed.
With none, the master was left open, unlabelled, and invisible to every
watcher.

## What changed

- `bin/lib/prepr-gate.sh` `_prepr_parents` also emits N for a plan line
  starting `SLICE: C<k> of #N` (the guard's anchored shape), so the PR body
  says `Part of #N`.
- `bin/lib/issue-state-lib.sh`: the guard's timeline read is factored into
  `_issue_open_children` (guard words unchanged). `issue_slice_settle` reads
  the children for `slice:plan` / `slice:no-keyword`: a child keeps today's
  path; none posts the no-children comment, keeps the label, raises one warn
  alert (`_issue_slice_alert`) and answers `kept-slice:no-children+label-kept`;
  an unreadable read answers `close-deferred:children-read` rc 1, which
  `issue_close_shipped` now passes through.
- `bin/lib/mc/classify.sh` `mc_close_shipped` takes the same three-way branch
  with its own `comment-deferred` rule.
- `bin/hotfix-after-deploy.sh` writes a `HOTFIX CLOSE-OUT OWED` line for the
  children-read deferral, since it drops the rc.

Suite: `tests/slice-closeout.bh-4662-test.sh`.

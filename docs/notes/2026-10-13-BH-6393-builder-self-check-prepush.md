# The builder runs pr-self-check before it opens or edits the PR (BH-6393)

Doc: RUN-BUILD-GRAPH

## What happened

Before this change the build ran only the `body-*` rules of
`bin/pr-self-check.sh` before it opened the PR (`--only '^body-'`). The
`plan-files`, `evidence-head`, `closes-not-met` and `test-ownership` rules ran
for the first time on the hub, in `self_check_hold` of
`bin/lead-review-enqueue.sh`, after the PR was open. The ticket counted 130
plan-files refusals on 44 PRs (57 PRs refused in total) from that gap.

A second cause: the settle stage in `bin/lib/rb/result.sh` rewrote the PR body
with a fresh `PR_BODY_FOR` render. That render dropped every section the
open-time fix round had added.

## What changed

- `_pr_self_check_prepush <body-file> <open|edit>` in `bin/lib/rb/pr.sh`
  (the `# >>> pr body fix round` span) replaces `_pr_body_fix`. It runs every
  catalog row (no `--only`, `--key $KEY`), at most 2 times.
- A `plan-files` refusal gets one line per unplanned file under
  `## Files outside the plan`, with no model turn:
  ``- `<path>`: changed in this build by "<commit subject>"; the plan's Files to touch does not name it.``
  The file list comes from the new `psc_plan_missing` in
  `bin/lib/pr-self-check.sh`, the same function the rule uses, so a list longer
  than the rule's 300-character message is complete.
- A `body-*` refusal still buys at most one fix turn, in the open phase only.
- What still refuses on the second check goes into the body under
  `## Pre-open check: refusals left`. That heading does not match the
  acceptance, self-check, evidence or Why section matchers, so a finding is
  never scored as a section. The PR opens either way.
- The settle stage renders its body to `$BUILD/pr-body-edit.md`, runs the same
  step in the `edit` phase, and sends that file to `gh pr edit`. The edit phase
  puts back `$BUILD/pr-body-fix.md` and writes reason lines for the head as it
  is at that time. It never buys a model turn.
- `$BUILD/self-check-prepush.txt` gets one line per phase:
  `<phase> tries=<n> verdict=pass|refused|could-not-run rules=<ids or ->`.
- `bin/pipeline-health.sh` (`# >>> self-check post-open count`) writes one
  line an hour to `logs/pipeline-health.log`:
  `self-check refusals after PR open by UTC day (heads/PRs): <day> <h>/<p> ...`
  for 7 days, newest first, from the enqueue's `state/lead-review-enqueue/selfcheck-*`
  files (`selfcheck-notes-*` excluded). A box with no such directory writes
  `not counted`. It never pages.

## Kill switch

`PR_SELF_CHECK=0` (env, or the `lead-review-enqueue` lane knob) turns off the
build-side step and the hub hold together. The build then logs one line and
opens the PR with the body as rendered.

## Known limit

The rule's reason-line regex escapes only `.[\*^$/`. A path with `+ ( ? |` can
still be refused after its reason line is written. It then lands in
`## Pre-open check: refusals left`.

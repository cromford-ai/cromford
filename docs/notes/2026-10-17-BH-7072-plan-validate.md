# The self-check runs the plan's static VALIDATE checks before review (BH-7072)

Doc: LEAD-REVIEW

In 12 lead BLOCKs in 14 days, a plan task or a body metric was not delivered. Each plan
already had the VALIDATE line that would fail. The pre-review self-check now has the rule
`plan-validate` (`bin/lib/pr-self-check-validate.sh`, the evaluator
`bin/lib/plan-validate.py`, the row in `catalog/pr-self-check.d/bh-7072-plan-validate.tsv`).

**Which plan.** The one `.harness/specs/<KEY>/plan.md` the diff changes, read at the head.
No such plan, or a plan with no VALIDATE line outside fences and the contract sections
(System invariants, Requirements coverage, Acceptance tests, QA screens, Verification,
Shared files, Spec changes from comments, Verify (run, not edited)): the rule prints nothing.
A human PR is not judged.

**Task ids.** A VALIDATE line belongs to the task above it: `### T3 — ...` or `Task 3` gives
`T3`. A line with no labelled task gets `L<line number>`.

**What runs.** Each backtick command on a VALIDATE line that has a static shape:

| shape | read from |
|---|---|
| `test -f\|-e\|-s\|-d PATH`, `[ -f PATH ]`, `test ! -f PATH`, `ls PATH` | `git cat-file` at the head |
| `grep` with `-c -q -n -E -F -i -w -x -s -h -e`, or `! grep ...` | the real grep, on temp copies of the head blobs |
| a grep whose file is `<PR body>`, `PR-body`, a path ending `pr-body.md`, or `gh pr view ... body ... \| grep` | the PR body |
| the plan's own path, on a VALIDATE line that says "PR body" | the PR body |

What the command must give comes from the words right after it: a comparator (`>= 9`,
`-ge 1`, `== 0`), `prints N`, `prints nothing`, `is empty`, `finds nothing`, `exits 0|1`,
`is at least N`, `prints one line`, `prints N for each file`. No words: a grep must match.
Words it cannot read (`shows only the header`, `prints 2 or 3`): the line is skipped.

Everything else is skipped and counted in one NOTE: a test-suite run, a pipe, `$`, `;`,
`&&`, a redirect, an unknown grep flag, a path with `..`, a glob, a git-ignored file (a
generated file is never at the head), prose. No VALIDATE text is ever handed to a shell:
plan text comes from untrusted ticket input, and the hub runs as root. The builder still
runs every VALIDATE line into `validate.txt`.

**The body.** The rule also refuses when the body:

- has a line that says `not met` (any case), outside fences, inline code, double quotes,
  a checked `- [x]` item and the `## Pre-open check` section;
- has a `Target metric:` line (`<id> from <a> to <b>`, or `<name> <op> <n>`) whose measured
  number misses it. The number is the one after `measured` on that line (`measured ... from x
  to M` gives M), else on one of the next 5 lines. No number, or `from a to a`, is a NOTE.

**owed: lines.** A body line `owed: <task id> <reason>` excuses that task when a PR
conversation comment approves it:

```
approve owed: T7
```

or `owed T7 approved` (any case). Only a comment by a login in the settings row
`trigger.actors.<project>` counts (cromford: `operator`). Any approved owed line also
excuses the body's not-met and Target metric findings. The comments are read only when a
finding exists and the body has an `owed:` line, at most 5 pages of 100
(`PLAN_VALIDATE_COMMENT_PAGES`). The builder's pre-open check has no PR number yet, so it
never sees an approval; the refusal says so.

**Where it runs.** The builder's pre-open check (`_pr_self_check_prepush`), the enqueue's
`self_check_hold` and gates 75/78 (`lgsc_run`). The two hub callers now pass `PSC_PR_REPO`,
`PSC_PR_N` and `PSC_PROJECT`. A refusal holds the review request, posts one PR comment, and
lets the review go after `PR_SELF_CHECK_MAX_WAIT_MIN` (30) with the findings in its note.

**Output.** `REFUSE plan-validate: T4: \`grep -c 'bake phases' <PR body>\` wants count >= 9 —
got 0`, `REFUSE plan-validate: body says not met: <line>`, `REFUSE plan-validate: Target metric
<target> measured <m> — not met`, one `NOTE plan-validate: T1 ok: \`<cmd>\`` per passing
check, `NOTE plan-validate: T4 owed (approved by operator)`, and one `NOTE plan-validate: <n>
VALIDATE line(s) skipped (not a static check): <ids>`.

**Knobs.** Turn the refusal off: set the row's mode to `note` or `off`. The whole self-check:
`PR_SELF_CHECK=0`. Operational caps (env): `PLAN_VALIDATE_MAX_LINES` (60 VALIDATE lines),
`PLAN_VALIDATE_GREP_TIMEOUT_S` (10), `PLAN_VALIDATE_BLOB_MAX` (2 MB). python3 missing or the
evaluator failing is one NOTE `could not run`, never a refusal.

**Hold rate.** Over the last 40 merged cromford PRs with a spec plan (to 549fb072) the
rule held 3, each on the plan's own check failing by its own words. Bodies were not replayed.

# A test belongs to its ticket: the self-check enforces D51 (BH-6392)

Doc: LEAD-REVIEW

## What happened

D51 says a new test case goes in its own file, keyed by the ticket. It was a
prompt rule only. In the 2026-10-06..13 study, 49 of 297 conflict pairs were
test files that two PRs edited. Test-file conflict pairs went from 16 to 25
after D51 landed. Nothing refused the edit.

## What changed

- `catalog/pr-self-check.tsv` has a new row, `test-ownership`, mode `refuse`.
  It sits after `plan-files`.
- `bin/lib/pr-self-check.sh` checks each file the PR modifies or deletes
  (`--diff-filter=MD`, base...head). An added file is never checked. The file
  must be under `tests/`, and its name must carry a ticket key:
  `<topic>.<key>-test.sh`, `.<key>.test.<ext>` or `.<key>.spec.<ext>`, where the
  key is `[a-z]+-[0-9]+(.N)*`. A name with no key is never checked.
- When the key root of that file is not the PR's own key root, the body must
  have a line `TEST-CHANGE: <path or basename> — <premise>`. The premise must
  hold 3 or more words. Else the rule refuses, one line per file, 10 lines max.
- The PR's own key comes from the first of these that gives one:
  1. `--key <KEY>` on `bin/pr-self-check.sh` (`PSC_PR_KEY`). The lead-review
     enqueue sets it from the PR title `BH-N: ...`.
  2. The `Harness-Ticket: <KEY>` trailer (`none` is not a key).
  3. The first body line, `Ticket <KEY> —` or `HOTFIX: Ticket <KEY> —`.
  4. The one `.harness/specs/<KEY>/plan.md` the PR changes.
- The key root is lower case with a `.N` slice suffix stripped, so the slices of
  one ticket own the tests of each other.
- No key from any rung: one NOTE, no refusal. No checked test of another key in
  the diff: the rule prints nothing.
- The builder never writes the PR body, so `PR_BODY_FOR` (`bin/lib/rb/pr.sh`)
  adds a `## Test changes` section from `psc_test_change_section`. It copies the
  plan lines under `## Tests that must change`, the plan's own `TEST-CHANGE:`
  lines and the `TEST-CHANGE:` lines in the commit messages (first source wins,
  one line per path).
- `th_plan_rule` (`bin/lib/test-home-lib.sh`) tells the planner to list those
  tests under `## Tests that must change`, or write `None`.
- `prompts/build-discipline.md` has rule D65 for the builder.

## Kill knobs

- Set the `test-ownership` row to `off` in `catalog/pr-self-check.tsv`.
- `PR_SELF_CHECK=0` turns off every self-check rule in the enqueue.
- A refusal holds the lead review for at most `PR_SELF_CHECK_MAX_WAIT_MIN`
  (default 30) minutes. Then the review is requested with the finding in its
  notes.

## Tests

`tests/pr-self-check-test-ownership.bh-6392-test.sh`.

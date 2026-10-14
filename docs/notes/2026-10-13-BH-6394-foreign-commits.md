# A PR carries only its own ticket's commits (BH-6394)

Doc: LEAD-REVIEW

## What happened

In 7 days, 24 of 458 ticket PRs carried commits of another ticket. #6355
(`ticket/bh-5905-r3`, base main) carried 3 BH-6308 commits, and it broke batch
#6368. The self-check read files and the body. It did not read commits.

## What changed

- `catalog/pr-self-check.tsv` has a new row, `foreign-commits`, mode `refuse`.
  It sits after `test-ownership`.
- `bin/lib/pr-self-check.sh` walks `git log --first-parent --no-merges
  <base>..<head>`. A commit that came in through a merge of main is not walked.
- A commit is foreign when its subject LEADS with a ticket key (`BH-1: x`,
  `fix(BH-1): x`, `spec(BH-1.2): x`) of the PR key's prefix and of another key
  root. A key later in the subject does not count. `UTF-8: x` has another
  prefix and does not count.
- The own key roots are the PR key (the same rungs as `test-ownership`: `--key`,
  `Harness-Ticket:`, the first body line, the one spec plan) and the second key
  of the first body line `Ticket BH-6008 — BH-6005.1: ...`.
- A foreign commit passes when:
  1. The base is `ticket/<that key>`, with an optional `-rN` or `-pN` suffix
     (`origin/` is stripped).
  2. The body has a `Stacked on #N` line AND the conductor row file holds THIS
     head as `STACKED_WAIT`. The file is `$PSC_CONDUCTOR_ROWS`, default
     `state/merge-conductor/pr-state.tsv` beside the lib. A row for an older
     head does not count.
- Each refusal names the 12-char sha, the subject, the key and the owner PR. The
  owner PR is one `gh_rest` read per key root (at most 3) when the caller has
  `gh_rest`, else the body's `Stacked on #N`, else `the PR of ticket/<key>`. The
  lookup changes only the message. 10 lines max, then `and N more`.
- No own key and a keyed commit: one NOTE, no refusal. A `git log` failure: a
  NOTE.
- Builder rule D66 (`prompts/build-discipline.md`): stack with the parent branch
  as base; never rebase a parent's commits onto main; if the parent merges
  first, merge main.

## Where it runs

Only `bin/lead-review-enqueue.sh` `self_check_hold` (all rules, base
`origin/<PR base ref>`, key from the PR title) and the CLI. CI and the build's
`_pr_body_fix` run `--only '^body-'` and never run it.

## Kill knob

Set the `foreign-commits` row to `off` in `catalog/pr-self-check.tsv`, or
`PR_SELF_CHECK=0` for the whole self-check. No deploy.

Tests: `tests/pr-self-check-foreign-commits.bh-6394-test.sh`.

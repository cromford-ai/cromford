# The pre-review self-check: a PR body must match its head (BH-5798)

Doc: LEAD-REVIEW

## What happened

38 review BLOCKs in the 2026-10-09 analysis were facts that git and the PR body
could tell without a model: 15 bodies described an older head, 11 said "Closes" on
a partial build, 9 missed a named acceptance item, 3 changed files outside the plan.

## What changed

1. **One checker, catalog-driven.** `bin/pr-self-check.sh check --repo --base --head --body`
   over `bin/lib/pr-self-check.sh` (`psc_check`). The rules are rows of
   `catalog/pr-self-check.tsv` (id, mode `refuse|note|off`, ignore globs). #5790's section
   rules join as more rows. Exit 0 pass, 1 refused, 2 could not run.
   - `closes-not-met`: Closes/Fixes/Resolves #N while an acceptance item is `- [ ]`,
     "not met" or REFUTED.
   - `evidence-head`: each evidence sha (`head <sha>` in a heading, or
     `<!-- evidence-head: <sha> -->`) is the head, or an ancestor after which none of the
     PR's files changed. No sha at all is a note.
   - `plan-files`: a diff file the plan's "Files to touch" does not name needs a line
     under `## Files outside the plan`.
2. **The builder says Refs on a partial build.** `bin/lib/rb/pr.sh`: a REFUTED claim in
   `evidence.json` turns `Closes #n` into `Refs #n`, lists the claims not met under
   `## Acceptance self-check`, and skips the close after merge. The Evidence section
   carries `<!-- evidence-head: <sha> -->`.
3. **The enqueue runs it before a lead review.** `bin/lead-review-enqueue.sh` holds a
   refused head (`skipped_selfcheck`), posts one PR comment per (head, body), and after
   `PR_SELF_CHECK_MAX_WAIT_MIN` (30) requests the review anyway with the findings in the
   scope note. Knob `PR_SELF_CHECK` (1).

## What usually lies

- A body updated by hand after a push still names the old sha in its headings: that is
  exactly what `evidence-head` refuses, and the fix is to rerun the evidence and update
  the sha.
- A risk-tier sign-off happens before the self-check and is not held by it.
- Filing the not-met items as new issues is not automatic yet; the body lists them.

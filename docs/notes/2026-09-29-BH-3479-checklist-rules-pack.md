# Lead review: a versioned checklist, the ticket thread, and the rules pack first (BH-3479.2, BH-3546)

Doc: MERGE-CONDUCTOR

## What changed

This is child 3 of 5 of BH-3479 (ticket BH-3546). Everything is inside the box
lane `bin/lead-review.sh`. No new lane, no new knob, no new `bin/lib` file.

- `prompts/lead-review-checklist.md` is new, and it is a required module like
  `prompts/lead-review.md`. When it is missing, the tick logs
  `missing prompts/lead-review-checklist.md; lead-review tick skipped` and
  claims nothing. Line 1 is `Checklist-Version: <N>`. The prompt is the brief,
  then the checklist, then the sections.
- The report header now reads, in order: verdict, host suite, rules pack,
  reviewer model, checklist (`- checklist: v1`). A checklist with no version
  line still reviews, logs it, and says `v?`. Line 1 of the report is
  unchanged, and the replay reads only `- reviewer model:` and
  `- host suite:`, so a report written before this change still replays.
- `## Ticket thread` sits after `## PR`. It reads the first `Closes #<n>` in
  the PR body (any case) that names this repo, bare or as `owner/repo#<n>`.
  It makes two `gh_rest` reads: the issue and its first 100 comments. It
  prints the issue body, then each comment as `### <login> at <time>`, newest
  last. The section says so instead when:
  - there is no such line: `(no Closes #<n> line in the PR body)`
  - either read fails: `(the ticket thread could not be read: HTTP <code>)`.
    Nothing partial is printed, because a body without its comments hides the
    latest word. The review still runs.
  - `LEAD_REVIEW_THREAD_MAX_BYTES` is empty (the registry could not be read):
    `(the ticket thread was not included: LEAD_REVIEW_THREAD_MAX_BYTES is unset)`,
    and there are no reads.
- Over `LEAD_REVIEW_THREAD_MAX_BYTES` the thread keeps its first and last
  half-cap bytes, with a `(ticket thread cut: ...)` line between them. The
  head is the spec and the tail is the latest word.
- `bin/rules-pack.sh` runs after the checkout and before the host suite, only
  for the repo fleet.conf names as `cromford`. It gets half of what is
  left of `LEAD_REVIEW_DEADLINE_S`. `## Rules pack` in the prompt and
  `- rules pack:` in the header carry one of `clean`,
  `could not run (rc N)` (plus a `stderr tail:`), `not installed on this box`
  or `not applicable to <repo>`.
- rc 1 from the pack is a BLOCK with no model call and no host suite. The
  report says `- rules pack: red` and `- reviewer model: rules-pack`, one
  `- [BLOCK]` line per finding, and ends `VERDICT: BLOCK`. rc 1 with no finding
  line still blocks, with one synthetic finding, and the stderr tail goes to
  `logs/lead-review.log`. A retried tick replays that report like any other,
  so the pack does not run twice and no call is made.
- `catalog/context-budgets.json`: the `lead-review` entry gains the three
  components and the `[lane:thread_cap]` bound.

## What usually lies

- `- rules pack: not applicable` on a cromford PR means this box's
  fleet.conf could not answer `cromford repo`. It does not mean the pack
  judged the PR.
- `could not run` still lets a model verdict through. The cap to
  MERGE-WITH-NOTES is the model's job, set by the checklist. The code does not
  rewrite the verdict.
- A thread with 100 comments may not be the whole thread. Only the first page
  is read, and the section says so.
- The middle cut uses byte counts, so a multibyte character can be split at
  the cut.

## Pinned by

`tests/lead-review-rules-pack.bh-3546-test.sh` drives the real tick: R1-R9
and a mutation that removes the `return` after the rules-pack BLOCK.

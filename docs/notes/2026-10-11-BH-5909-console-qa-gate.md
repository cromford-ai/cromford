# A console UI PR without QA: PASS on its head gets a lead BLOCK (BH-5909, slice 2)

Doc: MERGE-CONDUCTOR

## What changed

The lead review has a console QA gate (`bin/lib/console-qa-gate.sh`). It is off
until `LEAD_REVIEW_CONSOLE_QA_GATE` is 1 (settings row
`lane.lead-review.lead_review_console_qa_gate`). Turn it on after the preview
lane from slice 1 has posted its first green QA.

With the gate on:

1. **The box review blocks.** `bin/lead-review.sh` checks a harness PR that
   changes `console-ui/src/` right after the fetch, before the rules pack and
   before any replay. If no QA: PASS comment names the head, the review is a
   BLOCK with reviewer model `console-qa-gate` and no model call. The report
   names the full head sha and the comment that clears it. lead-review-land
   posts it to the PR as usual.
2. **A later QA: PASS clears it with no push.** Each `lead-review-enqueue` tick
   reads the standing verdict of each harness PR head. When it is a
   `console-qa-gate` BLOCK and a QA: PASS comment now names that head, the hub
   resets the lead review request (`POST /api/lead-reviews/<id>/reset`). The box
   reviews the same head again, and lead-review-land re-lands it and dismisses
   the earlier BLOCK review (BH-5400). One reset per PASS comment.
3. **No replay skips it.** The enqueue replays no lead MERGE onto a console
   head that has no PASS. The head gets a review instead.
4. **No fix round.** The blocked resolver briefs no fix round from a
   `- [BLOCK console-qa]` review. No code change answers it.

## What counts as a QA: PASS

One PR comment that has all of these:

- An author who can write (OWNER, MEMBER or COLLABORATOR), or the harness App.
  `bin/console-preview-deploy.sh` posts as the App.
- A line that names the head: `QA: PASS for head <sha>`, `QA-HEAD: <sha>`, or
  `<!-- console-qa sha=<sha> result=PASS -->`. The sha is the full head, or a
  prefix of 9 or more hex digits.
- A line `QA COVERAGE: screens=<n> ... shots=<m>` with n and m of 1 or more.
- No line that starts `QA: FAIL`.

## Tests

`tests/console-qa-gate.bh-5909-test.sh`. On main: 10 passed, 42 failed. On this
branch: 52 passed, 0 failed.

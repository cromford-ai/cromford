# The lead review reads an over-limit head in parts on the same head (BH-8533)

Doc: OPERATING, CALL-GUARD

## What changed

- A full lead review over `LEAD_REVIEW_DIFF_MAX_BYTES` that leaves a file
  unread was a `[BLOCK split-required]` with no model call. When the split that
  `ldp_build` proposes fits, `bin/lead-review.sh` now reviews the SAME head in
  N parts (`bin/lib/lead-part-review.sh`, loaded through
  `bin/lib/lead-review/libs.d/202610270120-bh-8533-lead-part-review.sh`).
- Each part is one paid call (model from `model_for lead.review`). Its prompt
  is the usual lead prompt, then `## Part review`: part k of N, the PR, the
  head sha, this part's files and every other part's files, then its own
  `## Diff coverage` and the whole-file diff of its files only. Every file that
  is not generated or a fixture is in exactly one part (checked against
  `git diff --numstat`, fail closed).
- The aggregate is ONE verdict: BLOCK when any part is BLOCK, else
  MERGE-WITH-NOTES when any part is, else MERGE. A part with no readable
  verdict, a part lost, a head move or a closed PR gives no verdict. The
  aggregate goes through the usual re-review downgrade, break-it, review-level
  cap, outcome cap and `finish_done`: one result row, one `lead-verdict`.
- The report header says `- review mode: part review, N parts (<pfp8>),
  parts: 1 MERGE, 2 BLOCK, ...`, and each part's answer is under
  `## Part k of N: <verdict>`. The log says `part review: N parts`.
- `ldp_build` writes the split as TSV (`<part>\t<over>\t<bytes>\t<path>`) when
  the env `LDP_PARTS_TSV` names a file. Unset, it writes nothing, as before.

## State and spend

- Before each paid part call the lane reads the jobs ledger, kind `lead_part`,
  key `<owner/repo>#<pr>@<sha>/p<k>of<N>/<pfp8>` (pfp8 = the first 8 hex of the
  sha256 of the partition). A part with a stored verdict is not bought again.
  An unreadable ledger is no call: the claim is released, not counted.
- The paid call's call-guard key is `lead:<repo>#<pr>@<sha>~p<k>of<N>x<pfp8>`
  on stage `lead-head` (K=1); the one no-verdict retry is `~p<k>of<N>n<pfp8>`.
- Each answer is stored before the next part: the local file
  `state/lead-reviews/parts/<owner_repo>-<pr>-<sha12>-p<k>of<N>.md`, the
  ledger row (status = the part verdict, detail = request_id, part, of, model,
  path, body, cut to 4000 UTF-16 units), and the job artifact
  `lead_review_part`.
- A part whose guard key is paid with no ledger row is `part-lost`: outcome
  failed, no verdict, and one warn through `bin/lane-alert.sh` with id
  `lead-part-lost-<owner_repo>-<pr>-<sha12>`. Recover: read the part's local
  file if this box has it, else
  `bin/jobs-client.sh call-guard-reset <project> lead-head "<fp>" "<reason>"`
  with the fp the alert names, then reset the request.
- The deadline is shared over the parts left. Under
  `LEAD_REVIEW_PART_MIN_LEFT_S` (60 s) for the next part is a release (nothing
  billed); the stored parts stay and the next tick resumes.
- One head can spend up to `LEAD_REVIEW_PART_MAX` calls past the daily spend
  cap, which is checked when the tick starts. The per-PR-day tripwire counts a
  part-review head once.

## Knobs (settings rows `lane.lead-review.<lower-case env>`)

- `LEAD_REVIEW_PART_REVIEW_ENABLED` (1): any value but 1 = off, the
  split-required BLOCK as before.
- `LEAD_REVIEW_PART_MAX` (8, 2..20): more parts = split-required BLOCK; the
  finding names the knob.
- `LEAD_REVIEW_PART_BYTES` (0 = `LEAD_REVIEW_DIFF_MAX_BYTES`): the limit of one
  part's section of the prompt.
- `LEAD_REVIEW_PART_MIN_LEFT_S` (60, 30..3600): the least time a part call
  gets from the deadline share; under it the claim is released.

When part review does not run, the split-required finding ends with
`Part review did not run: <why>` (off, over part_max, a file over the part
limit alone, the lib not loaded, a coverage fault).

Test: `tests/lead-part-review.bh-8533-test.sh`.

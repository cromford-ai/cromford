# The land lane posts a lead BLOCK's findings to the PR, and samples MERGE verdicts for a spot-check (BH-3479.3, BH-3547)

Doc: MERGE-CONDUCTOR

## What changed

`bin/lead-review-land.sh` gains two steps inside its `done` branch. Nothing
else in product code changes. It does not register a knob: the BH-3544 contract
already registers `LEAD_REVIEW_SPOTCHECK_PCT`.

### A BLOCK goes to the PR as a review (step 2b, `lrl_findings`)

Until now a lead BLOCK became a `source=lead` verdict row and nothing more.
That row gates the merge, but the fix round (`bin/blocked-resolver.sh`) briefs
itself from the PR's reviews, so it never saw the lead's findings.

Now, once a BLOCK row is recorded (`bin/lead-verdict.sh post` rc 0 or 4, or an
earlier tick's row found on the head), the lane posts the lead report to the PR
before it stamps the request promoted. The order is **row, then findings, then
flag, then stamp**.

- The review is `POST repos/<slug>/pulls/<n>/reviews` with
  `event=REQUEST_CHANGES` and `commit_id` = the reviewed head. It goes out under
  the hub's default gh identity, with no `gh_auth_for`. That is the shape
  `br_lead_pick` briefs a fix round from.
- The body opens with the contract's marker, `<!-- lead-review:<id> -->`, then
  `Lead review (automated lead-review lane, <reviewer_model>) of <head12>`,
  then the report:
  - the `lead_review_report` artifact's `.body` (`job_artifact_detail` on the
    request's `job_id`), when its first line is
    `# Lead review … (<slug>#<n> at <head>)`. A `truncated:true` artifact adds
    `Report truncated here; the full report is on box <box> at <path>`.
  - otherwise (no job id, no artifact, or a header naming another repo, PR or
    sha): `Full report: <report_ref> on box <box>`.
- Dedupe comes first, twice. The flag `state/lead-review-land/findings-<id>`
  means "already posted". Without it, the PR's reviews are read (100 a page, up
  to 10 pages), and a review of any author whose body carries the marker writes
  the flag and skips the POST. Losing the flag directory costs one reviews read,
  never a second review.
- A 422 on `REQUEST_CHANGES` (GitHub refuses it, for example, on a PR the same
  account opened) is re-posted once as `event=COMMENT` with the same body and
  head, and fires one warn: `bin/lane-alert.sh --severity warn --id
  lead-block-nobrief-<id>`. A COMMENT review briefs no fix round, and the warn
  says so.
- Not stamped, and retried next tick: a reviews read that fails, is not an
  array or hits a 10th full page; a jobs worker that cannot be read (rc 1, as
  opposed to "no artifact", rc 3); a POST that fails with anything but the 422
  path above, or a COMMENT re-post that fails too.
- A moved head (post rc 3) posts no row and no review, and is stamped as before.
- The PR's live head is read just before the POST too. A stamp-only retry can
  run after a push (the row was recorded, the POST kept failing, then the PR
  moved). A REQUEST_CHANGES on that dead head would be a standing review nobody
  fixes, so nothing is posted, no flag is written, and the request is stamped
  (`the PR head moved to <head12>; findings not posted`).

### A later lead MERGE dismisses the old BLOCK review (step 2d, `lrl_dismiss`)

GitHub keeps a reviewer's CHANGES_REQUESTED across pushes until that review is
dismissed or the same reviewer approves. `.mergify.yml` keeps a PR out of the
queue while `#changes-requested-reviews-by` is above 0 (BH-2275). The review
lane's own dismissal pass (`rp_dismiss_own`) only touches bodies carrying its
footer, and the lead body must not carry it, or `br_lead_pick` would drop it.
So without step 2d, a PR whose fix round went green, and whose lead re-review
said MERGE, would stay parked on the old BLOCK review until a person dismissed it.

- It runs when a MERGE or MERGE-WITH-NOTES row is recorded (this tick, or an
  earlier one on a stamp-only retry). It reaches GitHub only when the
  verdicts read shows a lead BLOCK row on another head of the PR, or came back
  truncated. A findings review is only ever posted after its row, so without
  such a row there is nothing to dismiss.
- The PR's live head must still be the MERGE head. If the PR has moved on, the
  MERGE speaks for nothing and dismisses nothing, and the request is stamped.
- Every page of reviews is read. Each review whose state is
  `CHANGES_REQUESTED`, whose body carries a `<!-- lead-review:` marker and
  whose `commit_id` is not the MERGE head gets
  `PUT repos/<slug>/pulls/<n>/reviews/<id>/dismissals` under the same default
  gh identity that posted it. A person's review is never touched, and neither is
  a lead BLOCK on the MERGE head itself.
- The flag is `state/lead-review-land/dismissed-<id>`. A failed read or a
  failed dismissal is no flag and no stamp, and the next tick retries.

### MERGE verdicts are sampled for a spot-check (step 2c, `lrl_spotcheck`)

When a MERGE or MERGE-WITH-NOTES row is recorded on this tick (post rc 0 or 4),
the lane computes `cksum("<slug>#<n>@<head>") % 100`. When that bucket is below
`LEAD_REVIEW_SPOTCHECK_PCT`, it fires one warn beat:
`bin/lane-alert.sh --severity warn --id lead-spotcheck-<id> lead-review-land
"spot-check: <slug>#<n> @<head12> lead <VERDICT> by <model>: https://github.com/<slug>/pull/<n> report <ref>"`.

- The sample is deterministic: a rerun picks the same heads.
- A BLOCK is never sampled, and neither is a stamp-only retry (the row was
  recorded on an earlier tick) or a moved head.
- `0` is off. A value that is not an integer 0..100, empty included, is logged
  once per tick (`LEAD_REVIEW_SPOTCHECK_PCT='<v>' is not 0..100; spot-check off
  this tick`) and treated as off. It is not clamped. In production
  `lane_env_apply` supplies the registry value (default 10).
- The beat never gates the stamp.

## Where to look

- `logs/lead-review-land.log`: `findings posted to the PR as a review on
  <head12>`, `its findings review is already on the PR; flagged`,
  `REQUEST_CHANGES refused 422; findings posted as a COMMENT`, `findings review
  NOT posted (HTTP <code>…)`, `PR reviews read failed`, `the report artifact of
  job <job> could not be read`, `the PR head moved to <head12>`, `dismissed
  <n> older lead BLOCK review(s)`, `dismissing lead review <id> FAILED`, and
  `sampled for a spot-check (bucket <b> <
  <pct>)`.
- The PR's Reviews tab: one `REQUEST_CHANGES` review per lead BLOCK request,
  shown as dismissed once a later lead MERGE lands on a newer head.
- The warn digest: `lead-spotcheck-<id>` and `lead-block-nobrief-<id>`.

## Pinned by

`tests/lead-review-land-block.bh-3479-test.sh` runs the real lane against a
stub jobs worker and a stub GitHub. It covers L1-L12 and a failed-row negative.
L11 pins the dismissal (the marker review dismissed, a person's review left
alone). L12 pins the dead-head retry.
L7 feeds the posted review to the real `br_lead_pick` lifted from
`bin/blocked-resolver.sh`.

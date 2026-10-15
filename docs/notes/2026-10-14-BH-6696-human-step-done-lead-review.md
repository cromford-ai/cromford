# A HUMAN-STEP-DONE answer to the builder's REQUEST_CHANGES requests the lead review (BH-6696)

Doc: OPERATING

## Why

On 2026-10-14 a person answered the NEEDS-HUMAN step on #6648 (BH-6260) and
#6620 (BH-5373) at about 12:00Z. Neither PR moved for 80 minutes. The pool
skipped both tickets (`open PR exists`). `bin/lead-review-enqueue.sh` skipped
both PRs: `the builder's REQUEST_CHANGES on <sha12> stands; the fix round owns
it`. No fix round ran, because the step was a human step. A person sent
`bin/lead-verdict.sh request` by hand at about 13:27Z.

## What changed

`bin/lead-review-enqueue.sh` has a new rung, `stepdone`, in its builder-verdict
step. It uses the new lib `bin/lib/lead-step-done.sh`. All of these must be true:

1. The builder verdict is REQUEST_CHANGES or BLOCK, and its `reviewed_sha` is
   the PR head.
2. The PR author is a confirmed non-lead (`rt_lead_skip` leaves `RLEAD` empty).
3. The ticket issue (`to_pr_issue`: Closes #n, Refs #n, then the key in
   `ticket/<key>`) has a NEEDS-HUMAN: comment. After the newest one, a
   non-bot comment opens with `HUMAN-STEP-DONE:`, or with the capital word
   `RESUME` and no negation (`HOLD_NEG_RE`) and no condition after it
   (`RESUME once #12 merges`).
4. That comment is strictly newer than the `updated_at` of the builder's
   `verdict` artifact (`GET /api/verdict`).

Then the head goes on through the normal request path (standing verdict,
traced hold, silence check, risk tier, self-check, caps, ledger). It skips the
lead replay and delta block, so it always gets a full lead review. `REQFOR` is
set, so the risk tier never signs it off. The scope note starts
`auto: HUMAN-STEP-DONE after the builder's <V> on <sha12>` and carries
`human step answered after the builder's <V>: <url> by @<login> at <at>: <text>`
(600 characters at most). The log has one line
`<slug>#<n> @<sha12>: the builder's <V> is answered by <url> (@<login> at <at>);
requesting a lead review on the same head`.

If no answer is found, the skip is today's skip with today's text. If the
issue, the verdict time or the thread cannot be read, the skip is the same,
and its reason ends `; human-step check: <why>`. No new knob: a revert turns it
off. The pool is not changed.

## Second case: a refusal on an earlier head

A builder REQUEST_CHANGES or BLOCK whose commit is not the current head does
not stand. A fix round pushed since. The tick treats that head as unapproved,
the same as an APPROVE on an earlier head: replay, then the CI gate. The log
has `<slug>#<n> @<sha12>: the builder's <V> is on <old12>, an earlier head; it
does not stand on this head`. With LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 the
tick skips with `[skip no-approve]`. A refusal on the current head still stands.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue-human-step-done.bh-6696-test.sh`

# review-prs re-reviews a blocked external PR's new head on GitHub (BH-5396)

Doc: CALL-GUARD, OPERATOR-SETUP

## Why

project-3 #480/#481/#482 (`agent/*` branches by collaborator-1) carried this lane's
CHANGES_REQUESTED on head A. The author pushed fix head B with green CI, and no
review of B ever showed up on the PR. No alert fired either. The project-3 log was
not readable from the build box, so the exact skip line is still unconfirmed.
Reading the code turned up three paths that settle or skip head B on an external
PR with nothing posted to GitHub and no clock running:

1. `# >>> review-prs bought`: `review_bought` hits on another lane's verdict at B
   (an `mc_rereview` rrverdict row written by the merge conductor or
   `bin/blocked-resolver.sh`, a lead/human/box row, a run-build history round).
   The lane recorded that verdict as its own and posted nothing. The stale
   CHANGES_REQUESTED stayed up, and every later tick read B as already reviewed.
   This was reproduced against main: 0 agent calls, state
   `reused_from:"mc-rereview"`.
2. `rp_rehydrate` rung 1: a D1 `/api/verdict` row at B (a foreign build or
   review-rescue row that points at the PR) was replayed as this lane's verdict.
3. The before-billing `continue` (rc 74..79, usually the call-guard refusing a
   key another lane already charged) logged "retries next tick" on every tick,
   with no alert.

## What changed

- **Stale-CR** (`# >>> review-prs stale cr` in `bin/review-prs.sh`): a
  non-harness-authored PR whose row holds this lane's REQUEST_CHANGES on an
  older head, and whose new head is not patch-identical (the replay block still
  runs first). That head:
  - skips `review_bought` reuse;
  - calls `rp_rehydrate <num> <sha> gh-only`, which skips the D1 rung. Only this
    lane's own review on GitHub at that head counts as already paid, and a D1
    outage cannot hold the head;
  - buys under the call-guard key `review:<slug>#<n>@<sha>~stalecr` (stage
    `review-head`), so it gets one more read under its own key. This is the same
    pattern `~rereq` and `~stepup` use;
  - logs `… new head after this lane's REQUEST_CHANGES on <A7> (external PR):
    reviewed on GitHub, not settled from another lane's verdict
    REREVIEW_REASON=stalecr` just before the call.
  The green-CI debounce still runs first. An APPROVE dismisses the old blocking
  review through the BH-2119 supersede pass. A REQUEST_CHANGES at B becomes the
  standing review.
- **Stale-head watch** (`rp_stale_head_watch`, run after each PR in both the
  pool worker and the inline loop). It watches any row whose verdict is
  REQUEST_CHANGES on a head older than the PR's current one, unless that head is
  CI-deferred, since the CI path already has its own 12h alert. It writes
  `stale_head_sha` / `stale_head_since` the first time it sees the head. After
  `REVIEW_CI_STALE_SECS` (default 43200, an existing knob) it writes ONE ALERTS
  line naming the head, the hours waited and the PR URL, and quotes the last log
  line about that head (cut to 300 chars). After the alert it stamps
  `stale_head_alerted_sha`. The watch stops once the row's sha reaches the head,
  and a newer head restarts the clock.

Harness-authored PRs are not stale-CR: their REQUEST_CHANGES posts as a COMMENT
review, so it cannot block them.

Pinned by `tests/review-prs-stale-cr.bh-5396-test.sh`.

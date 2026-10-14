# The fix-round preflight is capped per head, never truncates a PR body, and trusts only verdict authors

Doc: fixround-preflight

## What changed

Follow-ups to BH-1794 (#1986), all in `bin/lib/fixround-preflight.sh`,
`bin/blocked-resolver.sh` (`br_preflight`, `br_preflight_after_push`,
`br_findings`, `br_rereview`) and `bin/review-prs.sh`
(`# >>> review-prs rereview request`):

1. **Waits are capped per head.** `wait`/`skip` are counted on the park record
   (`preflight_wait_head`, `preflight_wait_n`, `preflight_wait_first`). After
   `BR_PREFLIGHT_WAIT_MAX` (default 6) on one head the round runs. CI `none` for
   `BR_PREFLIGHT_NOCI_S` (default 1800 s) since the first wait reads as
   `unreadable`, so the round runs. A moved head restarts the count; a wait the
   record will not take runs the round.
2. **A begin marker with no end is refused.** `_frp_splice` exits 4 (and prints
   the body unchanged), `frp_body_refresh` returns the new rc 4 and sends no
   PATCH, and `br_preflight_marker_alert` sends one alert per PR
   (`marker_alerted`, recorded before the send).
3. **The review-lane route waits for the review lane.** After an
   evidence/rereview route on a `review-changes-requested` park
   (`preflight_route_at`), the round is deferred until a verdict author has
   reviewed the head since, or `BR_PREFLIGHT_DEFER_S` (default 1800 s) passes.
4. **Trust.** `br_findings` briefs a conductor park only from a verdict
   author's "Head-bound" comment (rc 75 if the trust set is missing). The
   re-review request is a PR comment from the hub; `bin/review-prs.sh` honours
   it only from a `harness_verdict_author_match` author. The body marker is
   still written but triggers nothing.
5. **Budget.** The preflight's conductor re-review calls
   `br_rereview … preflight`: counter `preflight_rereviews`, log tag
   `[preflight-rereview]`, not gated by `BR_NOVERDICT_MAX` or the lane-failure
   cap (it is once per head through `preflight_heads`).
6. **Hand lanes.** No hand-lane fix-round entry point exists in this repo. The
   lib header now documents the sourcing contract a caller follows.

## Why

BH-1992: the #1986 review found a stuck check-run or a head with no CI could
park a PR forever, an unbalanced marker truncated the PR body (everything
below it, `## Evidence` included), the evidence route mostly just delayed the
round, and anyone who could comment could write the fix round's brief or
trigger a re-review.

## Knobs

`BR_PREFLIGHT_WAIT_MAX`, `BR_PREFLIGHT_NOCI_S`, `BR_PREFLIGHT_DEFER_S`, all in
`catalog/lanes.d/blocked-resolver.json`; `0` = off for each.

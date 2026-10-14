# The review lane's APPROVE is the App's, and it supersedes the lane's own stale blocking review

Doc: MERGE-CONDUCTOR

## What changed

- **`bin/review-prs.sh` posts an APPROVE on the App token** (`gh_auth_for`),
  like `--comment` and `--request-changes` already did. The default credential
  (the fleet PAT, `operator`) is kept for one case only: the PR's author is the
  reviewing App itself, which GitHub refuses with a 422. `rp_author_is_reviewer_app`
  answers that. If it can't read the App's login (no slug or name in
  `env/github-app.env`), it answers yes, so the lane falls back to the old
  default and never risks a new 422.
- **A landed APPROVE of head H supersedes the lane's own older blocking
  reviews.** Right after the post, the reviews are read once more and
  `rp_dismiss_own` runs with H kept. It gets a new optional fourth argument:
  the message. That message cites the APPROVE's review id and the head. Only
  this lane's footer rows by a harness login are touched, and only on a PR by a
  NON-harness author (the per-tick BH-872 pass covers harness PRs). A
  refused APPROVE (comment fallback), an unreadable list or a low GitHub budget
  dismisses nothing. The pass writes no `ledger_sha`.

## Why

On project-5, 2026-09-24 12:39-12:40Z, the lane approved the fix heads of #3244,
#3214, #3259 and #3269. Every approval showed as `operator`. The App's own
CHANGES_REQUESTED on the older heads kept standing. GitHub keeps one standing
review per reviewer, so an approval from a different login never replaces it.
#3244 stayed blocked until the lead dismissed the review by hand.

The existing per-tick dismissal pass did not catch it because it runs inside
`if harness_pr_author_match "$AUTHOR"`, and when this was written pool PRs,
opened by `cromford-builders[bot]` since BH-1578, were outside the harness
author set. #1926 (BH-1668) has since put `app/cromford-builders` in the
default set, so on main a builders PR IS a harness PR and the per-tick BH-872
pass dismisses the App's stale review there, once, before the review. The
supersede pass is therefore guarded to NON-harness authors only
(`! harness_pr_author_match "$AUTHOR"`): it covers any PR the per-tick pass
does not, such as an external contributor's, and never dismisses a row twice.

## What it touches

- A review-prs APPROVE is now authored by `cromford[bot]`, a machine login.
  `bin/lib/block-gate.sh`'s third clear (`bg_verdict_clears`: the same machine
  login's later `VERDICT: APPROVE` naming this head) can now fire on it. That
  means a BLOCK comment the same App posted on that exact head is cleared by the
  lane's APPROVE of it. Before this, the APPROVE came from `operator` and could
  never clear anything that way. A person's BLOCK is unaffected: the drop is per login.
- The rehydrate rung and `br_review_newest` match approver logins through
  `harness_pr_author_match`, which already accepts `cromford[bot]`.
- Pinned by `tests/review-prs-app-approve.bh-2119-test.sh`. Case 20 of
  `tests/review-prs-dedupe-test.sh` now pins the default credential on the App's
  own PR instead of a `operator` one.

# BH-8466: review lanes recognise their own reviews under PAT auth

Doc: AUTH

## Cause

BH-8419 (PR #8439) made `harness_verdict_author_match` (bin/lib/gh-pr-list.sh)
answer 0 only for an App spelling. The "is this our own review" readers used
that matcher too. A lane that falls to the default PAT (bin/lib/gh-repo-token.sh:
app, then the PAT, then admin) posts its review as the operator login. After
BH-8419 the lane did not see that row as its own. It bought the same LLM review
on every tick, and it never dismissed its own standing CHANGES_REQUESTED.
Production is on the App path today, so the trap was latent.

## Fix

1. bin/lib/gh-pr-list.sh adds three functions. `harness_verdict_author_match`
   stays Apps-only for verdict consumers (merge, autopilot).
   - `harness_own_review_match <login>`: rc 0 for an App in the verdict set or
     the bare `HARNESS_OPERATOR_LOGIN`. An empty operator login matches nothing.
   - `harness_own_review_marked <body>`: rc 0 when the body contains
     `Automated harness review (Fable) of ` or starts with `<!-- lead-review:`.
   - `harness_own_review_row <login> <body>`: an App row, or an operator-login
     row that is marked. A row with no footer is a person's, whatever the login.
2. The own-review readers accept the operator login: bin/review-prs.sh
   `rp_dismiss_own`, the rehydrate GitHub rung and the re-review request;
   bin/blocked-resolver.sh `br_review_harness_pick` and `br_review_after`;
   bin/blocked-resolver.d/bh-8307-review-skip-note.sh `br_rsn_pick`;
   bin/lib/builder-review.sh `br_fetch`; bin/lib/br/cap.sh `br_cap_notes`.
   Each one also requires the footer, the lead marker or (for the re-review
   request) the `harness:rereview-requested` tag on an operator-login row.
3. bin/review-prs.sh `rp_pat_post_note`: on an App-armed box, a review post
   whose token is not an installation token (`ghs_`) writes
   `github auth: default PAT` to logs/pr-reviews.log, and one warn line per
   project per UTC day to logs/ALERTS.log (`--id review-prs-pat-<project>`).
   The day key is one overwritten file, `state/review-prs-pat-alert/<project>`.
   An unarmed box, and an APPROVE on the reviewing App's own PR, stay silent.

`br_lead_pick` is not changed: its lead arm needs a Bot row, and an
operator-login lead row already takes the association path.

## Tests

- tests/own-review-pat.bh-8466-test.sh (new).
- tests/verdict-author-person.bh-8419-test.sh C3 and D3, and
  tests/resolver-review-skip-note.bh-8307-test.sh P6: each pinned "an
  operator-login row with the footer or lead marker is a person's". That
  premise is reversed here; each case keeps its intent for a real person.

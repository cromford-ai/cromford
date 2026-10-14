# BH-5793: an environment failure never writes a BLOCK

Hotfix, built on the Mac (the operator, 2026-10-09: "lets hotfix the big ones now").

## The problem

Review lanes recorded BLOCK verdicts when no model had read the code, or left a
PR blocked on a verdict nobody could read.

- The rules pack ran a suite that the PR head did not carry (main added it
  after the PR branched). That is 48 findings in the 300-PR analysis, about
  24.5 BLOCKs per 100 reviewed PRs.
- A suite's own scratch repo failed to set up ("repo setup failed"): 13 findings.
- #5282: verdict #977 came from the rules pack after "repo setup failed".
- #4034 and #5379: the conductor logged "body unreadable — no classification,
  block stands", and the PR stayed blocked.
- #5199 and #5735: the lead review failed at checkout and was never retried.

## The fix

1. `bin/rules-pack.sh`: a suite the PR head does not carry is
   `could-not-run: <id>: suite missing at the PR head: <path>`, never a red line.
2. `bin/lib/review-env-fail.sh` names the environment-failure line shapes:
   - repo setup failed
   - a suite missing at the PR head, or `tests/<x>: No such file`
   - a ref that does not resolve
   - mktemp refused
   - a scratch guard refusal
3. `bin/lead-review.sh`: a rules-pack red made only of environment lines fails
   the request (`review-failed: env: <line>`), records no verdict and makes no
   model call. A red with real findings is a BLOCK on those findings only. Its
   environment lines are kept as NOTEs.
4. `bin/lead-review-land.sh` (hub, lead token) requeues an environment
   failure: POST `/api/lead-reviews/<id>/reset`. That covers `checkout`,
   `no-checkout`, `empty` (no model verdict, which covers a timeout and a model
   error) and `review-failed: env:`. It stops when `reset_count` reaches
   `LEAD_REVIEW_ENV_RETRY_MAX` (default 3, a lanes.d knob). Past that, one
   ALERTS line, as before.
5. `bin/lib/mc/block-ci.sh`: an unreadable block body is read a second way,
   from the PR's own review on that head. If that fails too, the conductor
   writes a `rereview` pr_attempts row first, then requests ONE re-review of
   the head (`bin/lead-verdict.sh request`, or `reset` of the finished
   request). Observe mode only logs WOULD.
6. `bin/lead-review-env-sweep.sh [--apply]`: the one-time clean-up. It finds a
   `done` lead BLOCK whose findings are all environment failures, on an open
   PR at that head. It writes the ledger row `lead_block_env_superseded`, then
   resets the request for a re-review. Without `--apply` it only lists them.

## Run the sweep (hub, once, after deploy)

    bin/lead-review-env-sweep.sh            # dry run: would-supersede lines
    bin/lead-review-env-sweep.sh --apply    # supersede and requeue

## Tests

- `tests/rules-pack.bh-3510-test.sh` R18.
- `tests/lead-review-rules-pack.bh-3546-test.sh` R10 and R11.
- `tests/lead-review-land.bh-1951-test.sh` L6b to L6d.
- `tests/block-gate-ci-clear.bh-3929-test.sh` V2 to V2i and V3. V2 and V3 are
  TEST-CHANGEs, because the unreadable block now asks for a re-review instead
  of standing.
- `tests/lead-review-env-sweep.bh-5793-test.sh` S1 to S8.
- `tests/lead-review-lane.bh-2202-test.sh` R2 and R2b.

## Review fixes (2026-10-09, lead review lr-5809-b2360d16170d)

- BLOCK: a requeued `empty` request was never reviewed again. The box's
  `state/lead-reviews/<key>.empty` marker is keyed by PR and head, so the box
  that claimed the reset request replayed the old `empty` with no model call.
  The marker now records the request's `reset_count` (`reset=<n>`). A retake of
  the same request still replays it, so nothing is paid twice. A request at a
  higher reset gets a real review, and the stale marker is removed. A marker
  with no `reset=` line counts as reset 0. Tests: R2 and R2b.
- NOTE taken: the `does not resolve` pattern is anchored to the runner's own
  wording, `base <ref> does not resolve`. A real finding that ends in the same
  words stays a real finding. Test: S7.
- The other NOTEs stand as written in the review. None changes what merges.

## Review fixes (2026-10-10, lead review lr-5809-1a62fbb06f34)

- BLOCK (both findings): the box's disk report `<key>.md` is keyed by PR and
  head too, so the env sweep's reset and the conductor's new request on the same
  head replayed the old BLOCK with no model call. A report or `.empty` marker is
  now replayed only when it was written at or after the request's latest start
  (`reset_at`, else `created_at`). A watchdog retake of the same claim still
  replays, so nothing is paid twice; an older file is removed and the request
  gets a real review. A request with no start time keeps the old behaviour.
  Tests: lane R7a to R7d.
- NOTE taken: without `bin/lib/gh-rest.sh` the sweep cannot check the PR state,
  so it supersedes nothing and says why. Test: S8.

## Review fixes (2026-10-10, lead review lr-5809-fd9e59c3edcc)

- BLOCK: the conductor's fallback read of an unreadable block body took the
  newest review on the head with any `VERDICT:` line. A tier or builder review
  that only said "CI did not run" could stand in for a lead block with real
  findings, and the CI-only clear is irreversible. `_mc_bci_head_review_body`
  now reads only the lead's own BLOCK review of this head: a Bot author, the
  `<!-- lead-review:` marker, the `# Lead review lr-<num>-<head12> (` title of
  this head, and a BLOCK verdict in the body. Anything else is no body, so the
  block stands and one re-review is requested. Tests: V2e (TEST-CHANGE: the
  fixture is a real lead review now) and V2f to V2i.

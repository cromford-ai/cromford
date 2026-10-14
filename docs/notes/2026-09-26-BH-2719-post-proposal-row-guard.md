# post-proposal asks the proposal row before it posts (BH-2531 part 3, BH-2719)

Doc: DB-COORDINATION-SPEC

## What changed

`bin/post-proposal.sh` creates one thing the client sees: the `[Proposal]`
ticket on their board. Before this change nothing checked whether that proposal
had already been posted. A box whose `state/product-<project>.ledger.json` was
wiped, or restored from an older copy, posted the same ticket again. It now uses
the `product_proposals` row (BH-2717, `bin/lib/proposal-rows.sh`) as the dedup
record:

- `HARNESS` can be overridden (`HARNESS="${HARNESS:-/root/harness}"`), which is
  what lets a scratch harness run the real script.
- It sources `bin/jobs-client.sh` and `bin/lib/proposal-rows.sh`, then runs
  `prow_restore` before it looks up the slug.
- The guard runs before any board call:
  - The file's last entry or the row says `posted`: it prints `already posted`
    to stdout and exits 0.
  - The row says `posting`: one ALERTS line, exit 1. An earlier post died
    between claim and stamp, so someone checks the board.
  - A configured worker that cannot answer: one ALERTS line, exit 1. This also
    covers `JOBS_URL` set but the lib missing.
  - No row: post.
  - `JOBS_URL` empty: the file-only path, as before.
- The claim: the row goes to `posting` before the create. A claim that does not
  land means no create, one ALERTS line, exit 1.
- The create no longer uses `curl -f`, so its HTTP code is read:
  - curl rc 6/7, or a 4xx: the row goes back to its pre-claim status. The
    existing `ticket create failed for <slug>` line now carries
    `(curl rc N, HTTP C; ...)`.
  - A timeout, a 5xx, or a 2xx with no id: the row stays `posting` and the
    alert says to check the board. A re-approve then alerts instead of posting
    a second ticket.
- Right after a create that returns an id, the file entry and the row are both
  stamped `posted` with `ticket_id` and `ticket_url`, before the attachments.
  The final ledger step writes the row again with the key and mockup URL.

`bin/lib/proposal-rows.sh` changed only in its header comment, which now names
post-proposal as its first consumer. Its suite's G1 check now allows
post-proposal and requires it to source the lib.

## Named condition

Until the harness-jobs route (`/api/product-proposals`, sibling slice BH-2718)
deploys, a box with `JOBS_URL` set gets the router's `unknown endpoint` 404.
`prow_get` reads that as unusable, so that box refuses to post a proposal and
writes an ALERTS line on every attempt. This fail-closed behavior is intended.
Boxes with `JOBS_URL` empty are unaffected.

## Merge hold (fleet rule BH-1000: a gating PR proves its dependency live)

This change gates the proposal-post lane on that route, so it must not land
before the route answers in prod. At 09:28Z on 2026-09-26 it did not:

    $ _jobs_req GET "/api/product-proposals?project=project-1&proposal_id=__probe__"
    rc=2 body={"error":"unknown endpoint","worker":"harness-jobs"}

#2719 carried `Blocked-by: #2718 (hard)`, so `pdg_hold` held this PR in every
merge lane while #2718 was open. #2733 merged and #2718 closed at 09:48:30Z,
which lifted that hold. Merging is not deploying, so the route was probed again
with the jobs secret. At 11:32Z on 2026-09-26 it answers in prod, and a made-up
path on the same worker still gets the router's miss:

    $ JOBS_URL=https://harness-jobs.operator.workers.dev; . bin/jobs-client.sh
    $ _jobs_req GET "/api/product-proposals?project=project-1&proposal_id=__probe__"
    rc=2 http=404 body={"error":"proposal not found"}
    $ _jobs_req GET "/api/no-such-route-bh2719"
    rc=2 http=404 body={"error":"unknown endpoint","worker":"harness-jobs"}

The same probe and its output are in the PR body.

## Tests

`tests/post-proposal-rows.bh-2719-test.sh` runs the real script under a scratch
harness against a stub worker and a stub board, and counts board creates:
P1-P8, B3 and B3b.

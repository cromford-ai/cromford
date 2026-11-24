# BH-9901 (BH-9887 slice C2) — the board approval request closes on merge or close, and the console and MCP show the wait

Doc: MERGE-CONDUCTOR, MCP

## The defect

Slice C0 (#9896) asks the product board for the client's approval of a head
that client mode withholds, and keeps the request id in a box-local marker
(`state/client-approval/<project>/<pr>-<head>.json`). Nothing closed that
request when the PR merged or closed, so the board kept asking the client to
approve a change that was no longer open. The console and MCP `pr_stage`
showed nothing about the wait: the marker is box-local, and they read the hub
only.

## The change

1. `bin/merge-conductor.sh` calls `mc_ca_close_tick "$SLUG" "$OPEN_NUMS"`
   after `mc_offlist_settle_tick`, inside the `MC_BUDGET_LOW != 1` block, when
   a fragment defines it.
2. `bin/merge-conductor.d/bh-9901-client-approval-close.sh`
   (`mc_ca_close_tick`): for each PR of the project with an open request
   (`ca_close_candidates`) that is NOT on the open list, the end state comes
   from the conductor's own row (`MERGED`/`CLOSED`) or closed-watch memo
   (`merged`/`closed`). No GitHub read. Any other answer: skipped this tick.
   At most `client_approval_board.close_max_per_tick` (seed 10) spawns a tick.
   Observe mode or the kill switch: a `WOULD` line. A keyed tick or a switch
   that is not `on`: nothing.
3. `bin/client-approval-close.sh <project> <slug> <pr> <merged|closed>`:
   under the request script's per-PR lock, it POSTs
   `{board}/tickets/{ticketId}/approval-requests/{id}/close` for the newest
   request of the PR, with `Idempotency-Key:
   client-approval-close:<project>:<pr>:<rid>` and body `{reason, prNumber,
   headSha}`. 2xx/409: `close=closed`. 404: `close=gone`, no ALERTS line.
   Else: `close_attempts+1`; at `retry_max` `close=cap-spent` and ONE ALERTS
   line (`client-approval-close-<project>-<pr>-<rid12>`). An older head's
   request is marked `superseded` with no call; a request with no id is
   marked `no-id` with no call.
4. The hub ledger row (kind `client-approval`, key `<owner/name
   lowercased>#<pr>`, format `client-approval-ledger v1`): the request script
   writes `waiting` after the board takes the request; the close script
   writes `closed` after a close answer. `ca_hub_put` is the one writer. A
   failed write sets `hub=pending` and is retried (no second POST, no second
   comment); at `retry_max` `hub=cap-spent`. A `done` marker with
   `hub=pending` is not settled (`ca_mark_settled`).
5. Console: the PR page header and the project BUILDS row STAGE cell show
   `WAITING FOR CLIENT APPROVAL · <age>` and `ticket <id> ↗` (the board
   ticket link, `ticket_url`) while the row is `waiting` and the build is not
   merged. Readers: `console-ui/src/lib/client-approval.js`.
6. MCP `pr_stage`: a fourth parallel read of the ledger row; the output
   gains `client_approval`, and `blocked_on` reads `waiting for client
   approval` when nothing else blocks.

## Answers

- Marker v1, additive fields: `hub`, `hub_attempts`, `close`,
  `close_attempts`, `close_last_http`, `close_reason`, `closed_at`.
- Switch off (`client_approval_board.<owner>.<name>`): no close call and no
  hub row for that repo.
- A lost marker (box rebuild) loses the request id: no close is sent, and the
  hub row stays `waiting`. The console hides the tag once the build is merged.
- Ledger retention: one row per PR (upsert). An operator adds
  `client-approval` to `retention.ledgers.archive_kinds` if the rows ever
  matter.
- Tests: `tests/client-approval-close.bh-9901-test.sh`,
  `tests/mc/client-approval-close-hook.bh-9901-test.sh`,
  `tests/client-approval-ui.bh-9901-test.sh`.

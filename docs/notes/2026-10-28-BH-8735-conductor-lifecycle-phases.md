# BH-8735: the conductor writes in_queue, ejected and merged (lifecycle 5/6)

Ticket: BH-8735. Part of the ticket-lifecycle rollout. Depends on #8731 (the
lifecycle API), and does nothing until it merges.

## What changed

- New conductor fragment `bin/merge-conductor.d/bh-8735-lifecycle.sh`. It holds
  the only code that sends the conductor's phases, through
  `lifecycle_transition` (`bin/lib/jobs/lifecycle.sh`, #8731) with actor
  `conductor`. It sources that lib only when the file exists.
- `in_queue`: the enqueue rc 0 and the re-entry requeue rc 0|2 in
  `bin/merge-conductor.sh`, and the requeue rc 0|2 in `sdq_arm`
  (`bin/lib/mc-stale-dequeue.sh`).
- `ejected`: the settle-pass ejection in `tick_project` (reason
  `mergify dequeue: <code>; checks: <cause>`), and `sdq_arm` when Mergify's
  newest payload says `dequeued` while our merge-queue label is still on and
  Mergify's queued/checking labels are not. That second case is once per
  payload comment (attempts line `lcdequeue <owner/repo#n> <head> <comment id>`),
  whatever the requeue decision is. Before, such a PR had no record of its
  ejection anywhere.
- `merged`: `conductor_settle` (`bin/lib/mc/settle.sh`), only when
  `pr_record_get <repo> <n> state` says `merged`. Any other answer is one
  `LIFECYCLE_MERGED_UNPROVEN` line.
- Every call is fail-open and always rc 0. Log lines: `LIFECYCLE` (moved),
  `LIFECYCLE_REFUSED` (rc 9, once per PR, phase and head through the attempts
  line `lcrefused <owner/repo#n> <phase> <head>`), `LIFECYCLE_UNREACHABLE`
  (rc 1 or 3). rc 9 with current == to and rc 2 (no build_queue row) are
  silent.
- The Tackler infra collector's parks (`unblock_infra_src parks`,
  `bin/lib/unblock/collectors/infra.sh`) read
  `GET /api/ledger?kind=pr_state&status=BLOCKED_HUMAN&limit=<n>` instead of
  `state/merge-conductor/pr-state.tsv`. The rows are the ones `mc_ledger_put`
  writes on every conductor state change. The record format does not change.
  A page of exactly `<n>` rows marks every park record truncated.
- `GET /api/ledger` takes an optional exact `status` filter. With no status,
  the query text is the same as before. A new additive index
  `idx_ledgers_kind_status_updated (kind, status, updated_at, key)` serves the
  filter and the order (`worker/jobs/schema.d/202610292200-bh-8735-ledgers-kind-status-updated-index.sql`).

## Knobs

- `MC_LIFECYCLE_WRITE` (merge-conductor, default 1; 0 = no lifecycle call).
- `MC_LIFECYCLE_REASON_MAX` (merge-conductor, default 500, max 500: the
  lifecycle route's own reason cap).
- `UNBLOCK_PARKS_READ_LIMIT` (unblock, default 1000, min 101, max 1000).

## Known gaps

- #8731 gives `ejected -> in_queue` to actor `lifecycle` only. The
  conductor's own requeue after an ejection gets 409 wrong_owner and one
  `LIFECYCLE_REFUSED` line, and the phase stays `ejected`, until #8731's owner
  map also lets `conductor` make that move.
- `mc_transition` writes the ledger only on a state change. A park whose
  reason changes inside BLOCKED_HUMAN shows its new reason to the collector
  after its next state change.

Doc: MERGE-CONDUCTOR

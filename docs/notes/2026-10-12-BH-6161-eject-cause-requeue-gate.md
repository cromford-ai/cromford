# Every queue ejection records its cause, and a requeue waits for a pre-queue run (BH-6161)

Doc: MERGE-CONDUCTOR, MERGIFY

## What happened

- #4735 (BH-4720) and #4029 (BH-3949) left the Mergify queue again and again. #4029 left it 6
  times between 2026-10-03 and 2026-10-08.
- Mergify stated a cause on every dequeue. Each comment has a `## Reason` section ("The merge
  conditions cannot be satisfied due to failing checks", with `Pure-logic gate fixtures` under
  "Failing checks:") and a "Left the queue … at `<sha>`" line.
- The conductor did not keep that cause. The settle arm wrote the row reason `queue-ejected` or
  `queue-ejected-twice`, and its log line said "the batch build went red" for every ejection.
- The BH-636 re-entry arm and the BH-3480 stale-dequeue arm put the SAME head back with
  `@mergifyio requeue`. No test run happened in between. When the pre-queue gate did run,
  `pq_resolve` reused the green verdict that let the head into the failed batch.

## What changed

1. **The cause is read and kept.** `bin/lib/mc-eject-cause.sh` (new). On each ejection the settle
   arm of `bin/merge-conductor.sh` calls `ec_cause` once and writes:
   - one log line: `EJECT_CAUSE <key> <head8> <first|again> <cause> (<detail>)`;
   - one record line in `state/merge-conductor/eject-cause/<owner_repo>_<num>`;
   - the row reason: `queue-ejected: <cause> (<detail>)`, or
     `queue-ejected-twice: 1 <cause> (<detail>) on <head8>; 2 <cause> (<detail>) on <head8>`.
   The ejection log line now says `cause: <cause> (<detail>)` and no longer says "the batch build
   went red". The re-entry arm keeps the cause in its `queue-ejected: <cause> … — push a fix` text.
2. **A requeue asks the pre-queue gate first.** The re-entry arm and `sdq_arm`
   (`bin/lib/mc-stale-dequeue.sh`) call `ec_requeue_gate` before the requeue budget. It calls
   `pq_gate` with `PQ_MIN_AT` = the ejection time (the record line, or Mergify's dequeue time).
   - proceed: the requeue goes on as before.
   - hold / defer: the row stays WAIT_CI `queue-ejected: requeue waits for the pre-queue run …`.
     No requeue unit and no `requeued` mark are spent.
   - red: BLOCKED_HUMAN `prequeue-red: …` and one `pqred` mark. The resolver's prequeue-red ladder
     owns it.
   - conflict: NEEDS_REBASE.
   One `REQUEUE_PREQUEUE <key> <head> main=<sha12> -> <word>` line per (key, head, main, word).
3. **No reuse of a verdict from before the ejection.** `pq_resolve`
   (`bin/lib/mc-prequeue.d/dispatch.sh`) skips every entry dispatched before `PQ_MIN_AT`. The
   exact (head, current main) entry is not filtered: the same inputs give the same answer.

## The cause table

The cause comes from the `## Reason` section of the newest `mergify[bot]` comment whose
Left-the-queue sha is this head. If no comment names the head, the newest comment with a
`## Reason` is read. First match wins:

| cause | when |
|---|---|
| `head-moved` | the PR head is not the queued head (no comments read), or the Reason says updated / synchronized / new commit |
| `batch-red` | the native GitHub queue (no comment to read) |
| `unknown` | the comment names another head, no Mergify comment has a Reason, or the comments read failed |
| `conflict` | the Reason says "conflict" |
| `review` | the Reason names `github-review-approved` unchecked (`mc_mergify_names_review`) |
| `timeout` | "timeout" or "timed out" |
| `checks` | "failing checks" or a `❌` line; the detail is the check names |
| `dequeued` | "dequeue" |
| `other` | anything else; the detail is the first Reason line |

## The record

One line per (head, first|again), the last 20 lines kept:
`<epoch>\t<head>\t<first|again>\t<cause>\t<detail>`. A record that cannot be written is one
`EJECT_CAUSE_UNRECORDED` log line, and the ejection goes on.

## Knobs

- `MC_EJECT_CAUSE` (default 1). 0 = no cause read, and the reasons and log text are the ones
  before this change.
- `MC_REQUEUE_PREQUEUE` (default 1). 0 = the two requeue arms ask no gate. The gate is also off
  when `MC_PREQUEUE_GATE=0` or the repo has no `prequeue-gate.yml`.
Both are lane knobs in `catalog/lanes.d/merge-conductor.json`, settable per project.

## Not in this change

- dequeue-watch's `_dqw_requeue` (`bin/lib/dequeue-watch/act.sh`) also requeues heads. It runs
  only when `DEQUEUE_WATCH_ACT=1` (catalog default 0). It does not ask the gate yet. A follow-up
  ticket owns it.
- An ejection from before this change has no record line, so its first gated requeue has no
  `PQ_MIN_AT` and uses the old reuse rule.

Tests: `tests/mc-eject-cause.bh-6161-test.sh`, `tests/mc-requeue-prequeue.bh-6161-test.sh`.

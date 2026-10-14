# BH-2133: the harness's own comments are not the board moving

Doc: EVENTS, repro-gate

Belongs with [gate-self-comments](../verification-map/gate-self-comments.md) and
[repro-gate/self-comment](../repro-gate/self-comment.md).

## What happened

On 2026-09-24 the cromford board was paused at 20:18Z. Triage shards were running every 30-60 s on
blocked tickets 2025, 2040, 2133, 1941, 1657 and 1174. Each shard posted a "still blocked, nothing edited" note as
`cromford-board[bot]`, and that note was the next shard's reason to run.

The mechanism was the GitHub-Issues gate fingerprint. It carries each issue's comment count and `updatedAt`, and
it had no self-write absorption. The webhook delivery of the same comment scoped an `event-wake` tick to that key,
and the shard fingerprint read the same moved row. #1389 carried six such notes by the time the operator wrote `HOLD`.

The same shape sat latent in the repro gate (#2133 as filed). `thread_fp` counted the stop's own comment, so
once #2040 wires the thread fetch, each re-offer would have paid for another drive and posted another comment.

## What changed

- `bin/lib/gate-self-comments.sh`: a row that moved only by comments from the harness's own Apps
  (`HARNESS_SELF_APPS`, `bin/lib/harness-self.sh`; never any bot, never the PAT) keeps its consumed values,
  and only when the issue's content hash (body, labels, assignees, milestone) is unchanged.
  One read per moved row, remembered after that. A human comment, any other field, or any doubt still wakes the
  tick. Switch it off with `flags/gate-self-absorb-off`.
- `pr_ledger_key` leaves harness comments out: `harness: true`, or the stop's `<!-- harness:repro-stop -->` marker.
- `pr_drive` claims before spending (a local flock and a `repro_gate_claim` row). A failed post-spend put now
  keeps a local record and raises an ALERT, and the lane and budget env are set after the env load.
- `pr_stop` escapes model text in markdown, links the origin-checked URL in-app, and a retry finds a delivered
  post by its marker instead of posting again.

## Rollout

The first tick after this lands still sees the rows that moved while the board was paused. Those rows were
consumed at the old values, so the bot notes posted since then are absorbed on that first tick. A human comment
posted in the same window still wakes it.

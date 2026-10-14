# Lead re-review asked at once on a head push (BH-5581)

Doc: OPERATING

## What changed

- `bin/lead-review-enqueue.sh pr <item>...` is a new per-PR mode. An item is
  `<owner/repo>#<n>=<trigger>` or `<owner/repo>@<sha>=<trigger>`. The run uses
  the same gates as the tick, for the named PRs only.
- A `pr` run asks for a head only when a source=lead MERGE, MERGE-WITH-NOTES or
  BLOCK row stands on an EARLIER head of the PR. A head with no such row, a
  head already in `state/lead-review-enqueue/requested.tsv`, or an unreadable
  or truncated verdict history is left to the `*/15` tick, with one log line.
- Each request a `pr` run makes writes one log line:
  `<repo>#<n> @<sha12>: immediate lead review request (<id>), trigger=<event>`.
  The run ends with a `pr repos=... trigger_items=<n> rung=<n>` summary. The
  `tick` summary is unchanged.
- A `pr` run holds `state/lead-review-enqueue/pr.lock`, never `tick.lock`, so it
  never makes a cron tick skip. A busy lock leaves the items to the tick. Only
  the tick prunes the ledger and the other state files.
- `bin/wake-loop.sh` on the hub collects items from `pr` wake rows
  (`pull_request.synchronize`, `pull_request.reopened`,
  `pull_request.ready_for_review`) and `checks` rows (`check_suite.completed`).
  It launches one `lead-review-enqueue.sh pr ...` per drain. Off the hub nothing
  changes. The logic is in `bin/lib/lead-reenqueue.sh`.
- New knob `LEAD_REENQUEUE_ON_PUSH` (int, 0..1, default 1) on the
  `lead-review-enqueue` lane. At 0 a `pr` run writes one line and exits.

## Why

The tick runs every 15 minutes. A re-pushed head waited for it. Measured
2026-10-07/08: median request-to-verdict 16.8 min (delta) and 19.7 min (full),
p90 41.5 min, against 49-75 s of real review time.

## Check it

- `grep 'lead-enqueue: launched' /root/harness/logs/wake-loop.log | tail -3`
- `grep 'immediate lead review request' /root/harness/logs/lead-review-enqueue.log | tail -3`
- Turn it off: set the `LEAD_REENQUEUE_ON_PUSH` settings row on the
  `lead-review-enqueue` lane to 0. The `*/15` tick still asks.
- Suite: `tests/lead-reenqueue-on-push.bh-5581-test.sh`.

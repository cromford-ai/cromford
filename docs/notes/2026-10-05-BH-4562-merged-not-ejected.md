# BH-4562: a PR Mergify merged is never logged EJECTED and parked BLOCKED

Doc: MERGE-CONDUCTOR

## What changed

- `mc_queue_left_why <owner/repo> <pr-url> <head-sha>` in `bin/lib/mc/queue.sh` answers
  why a QUEUED PR left the merge queue, always rc 0:

  | word | when |
  |---|---|
  | `merged` | a fresh PR read (`GH_ETAG=0`, no If-None-Match, so a 304 can't replay a cached OPEN) says GitHub merged it |
  | `merging` | still OPEN, but a Mergify queue check on the head has a title with `merged` in it ("Merged via merge queue"). Negated titles ("cannot be merged", "not merged") don't count |
  | `ejected` | OPEN with a stated reason: a failed queue check conclusion, a `dequeued` title, or Mergify's `dequeued` label |
  | `nowitness` | OPEN, the check read answered, none of the above |
  | `unknown` | either read failed, or the PR is CLOSED |

- The queue settle pass in `bin/merge-conductor.sh` (`# >>> queue left confirm (BH-4562)`)
  runs before anything about an ejection is written:
  - `mc_queue_state` answering `merged` (the PR landed between our two reads) settles it
    MERGED, for both providers. It used to fall into the ejection arm.
  - On Mergify it asks `mc_queue_left_why`. `merged` settles MERGED (`left the merge queue
    MERGED`). `merging` and `unknown` leave the row QUEUED with no strike. `nowitness` is
    held one tick per (PR, head) with an attempts line `qgone <key> <head>`, and a second
    sighting of the same head ejects as before. `ejected` runs the ejection arm unchanged.
  - The native GitHub queue never calls it: no extra read, no hold.
- `# >>> parked merged settle (BH-4562)`, right after the QUEUED loop: a row parked
  `BLOCKED_HUMAN queue-ejected-twice` or `WAIT_CI queue-ejected` whose PR GitHub reports
  MERGED is settled through `conductor_settle` (issue close, deploy request, stack follow),
  and its resolver hand-off is released (`mc_handoff_release <key> merged`). OPEN, CLOSED or
  unreadable leaves the row alone. Cost is one ETag-cached PR read per such row per tick.

## Why

On 2026-10-05 at 02:02:34Z the conductor logged #4142 `EJECTED from the merge queue again`
and parked it BLOCKED_HUMAN `queue-ejected-twice`. GitHub set `merged_at` at 02:02:35Z.
While Mergify lands a batch it drops its queued/checking labels and moves its queue check
before GitHub records the merge, so `mc_queue_state` saw no witness and answered `ejected`.
After that nothing settled the row. The open pass doesn't list merged PRs, the settle pass
read QUEUED rows only, and the closed pass memos `merged` without touching the row.

## How to check it on the hub

`grep BH-4562 logs/merge-conductor.log` shows `left the merge queue MERGED`,
`still QUEUED: Mergify's check says merged`, `held one tick` or `settled from the dequeue
park` lines. There should be no new `EJECTED … again` line for a PR whose `merged_at`
comes before the next tick.

Suite: `tests/mc/merged-not-ejected.bh-4562-test.sh`.

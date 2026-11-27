# BH-10257: the conductor's QUEUED pass reads the PR record

Doc: GH-REST, EVENTS

## Why

On 2026-11-26 the merge conductor made 77% of the fleet's GitHub calls (8,124 of 10,610 in hour 16). The App rate limit then stopped the fleet: 201 ticket skips in `logs/fly-pool.log`.

Most of the calls come from the QUEUED pass. On each tick it reads, for each QUEUED row: the reviews (`bg_cr_standing`), the PR (`mc_queue_state`) and, on Mergify, the queue check runs of the head.

## What changed

- `mc_queue_state_rec` (`bin/lib/mc/queue.sh`) gets the queue word through `prr_read merge-conductor "<slug>#<n>@<head12>:queue"`. The seam functions are `mc_qs_record`, `mc_qs_github` and `mc_qs_norm` in `bin/lib/prr-shadow.d/merge-conductor.sh`.
- The record answers only `queued`, which changes nothing. Every other word comes from GitHub.
- The record answers only when the row is at most `MC_RECORD_MAX_AGE_S` seconds old (default 900), is open, holds the QUEUED head, holds our trigger label (or queued/checking) and not `dequeued`, and (Mergify) has no red queue check on that head.
- In step `record`, a GitHub read is written back into the record. An idle QUEUED PR then reads GitHub once per 15 minutes.

Expected effect per QUEUED Mergify row per tick: 3 GitHub calls become 1 (the reviews read stays).

## Rollback

Set `lane.merge-conductor.gh_source` to `off`. The QUEUED pass then reads GitHub as before BH-10257. `MC_RECORD_MAX_AGE_S=0` also turns off only this read.

## What stays on GitHub

- Reviews. The record keeps the latest review per login, COMMENTED included, with no review id, association or marker. `bg_cr_standing` needs all of them. The next step: the webhook intake stores, per login, the latest review that is not COMMENTED and not a harness marker review.
- The pre-merge state guard, landing check-runs and the train reads. Each gates a write.

## Check after deploy

```
grep -c 'key=.*:queue' /root/harness/logs/prr-shadow.log
awk '$2=="merge-conductor.sh"' /root/harness/logs/gh-calls/$(date -u +%Y%m%d%H).log | wc -l
```

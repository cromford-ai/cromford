# BH-10257 slice 2: the QUEUED pass's view and CR reads come from the PR record

Doc: GH-REST, EVENTS

## Why

Hub `logs/gh-calls/2026112620.log`: 5,217 conductor calls in one hour, `pulls/{n}` 2,345, `pulls/{n}/reviews` 1,376, check-runs 802. The calls come per QUEUED row per keyed tick: one reviews read (`mc_cr_dequeue` -> `bg_cr_standing`), two `pulls/{n}` reads (the QUEUED-pass view and `mc_queue_state`) and one check-runs read. Slice 1 moved `mc_queue_state`. This slice moves the other two.

## What changed

- `mc_queued_view_rec` (`bin/lib/mc/queue.sh`): the view of a QUEUED row that the open list does not hold at its QUEUED head. Key `<slug>#<n>@<head12>:view`. The record answers only `OPEN <head_ref> <head>` (fresh, open, same head, and `fields_at.state` / `fields_at.head_sha` at most `MC_RECORD_MAX_AGE_S` old, so a lost closed webhook cannot keep a merged PR OPEN). MERGED and CLOSED come from GitHub. In step record a GitHub read is written back.
- `mc_cr_standing_rec` (`bin/lib/mc/queue.sh`): `mc_cr_dequeue`'s first CR read. Key `<slug>#<n>@<head12>:cr`. The record answers only "no CR stands", and only from a complete review set.
- New `pr_records` column `reviews_sync {head_sha, at, cr}` (`worker/jobs/src/lib/core.d/bh-10257-pr-records-reviews-sync.js`). Only the conductor writes it, with the `reviews` object of the same read, after a whole GitHub reviews read of that head.

## The completeness rule

The record serves "none" only when the row is fresh, open and on the head, `reviews` is not NULL, `reviews_sync` names the head with `cr` 0, `reviews_sync.at` is at most `MC_RECORD_MAX_AGE_S` old, and `fields_at.reviews` is earlier than `reviews_sync.at` (no review webhook at or after the read). `reviews_sync.at` is the read's start minus `MC_CR_SYNC_SKEW_S` (default 30 s). Anything else reads GitHub. The record never says a CR stands.

Expected effect per idle QUEUED Mergify row: about 1 GitHub call per `MC_RECORD_MAX_AGE_S` for each of the view, the queue word and the CR read, not 4 calls per tick.

## Rollback

`lane.merge-conductor.gh_source = off`, or `MC_RECORD_MAX_AGE_S=0`.

## Not moved

The open pass's reviews reads (`bg_scan`, the READY-arm `bg_cr_standing`), the pre-merge state guard, the parked-merged check, settle and landing reads.

## Check after deploy

```
grep -c 'key=.*:\(view\|cr\) ' /root/harness/logs/prr-shadow.log
awk '$2=="merge-conductor.sh"' /root/harness/logs/gh-calls/$(date -u +%Y%m%d%H).log | sed -E 's#/[0-9]+#/N#g' | awk '{print $4}' | sort | uniq -c
```

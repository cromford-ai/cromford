# BH-10213: a PR-record miss writes the GitHub answer back

Doc: EVENTS

In step `record`, lanes `pipeline-health` and `dequeue-watch` read GitHub after a PR-record miss. Before this change the answer was not stored, so the same miss came back at every tick (hub, 2026-11-26 10:07Z-10:27Z: 108 `:status why=none`, 32 `:payload why=none`, 22 `:payload why=field:updated_at`).

## What changed

- `prr_read` (`bin/lib/prr-shadow.sh`), step `record` only: after a miss it sets `PRR_READ_AT`, runs the GitHub fn with `PRR_NOTE=1`, and then calls the seam's `<prefix>_note <out> <github-rc> <why> [args]` once. Steps `off` and `shadow` call no note.
- A record fn that returns 0 and prints `hit-rc:<1-9>` is a hit that answers that rc. In step `shadow`, a different GitHub rc writes `PRR_SHADOW lane=<l> key=<k> rc_record=<n> rc_github=<n>`.
- New route `POST /api/pr-record-notes` (`worker/jobs/src/routes/pr-record-notes.js`). It replays the answer through the webhook SQL (`STATUS_MERGE_SQL`, `MERGIFY_SQL`, newer only). An empty answer sets the new column `pr_records.gh_empty` (`{statuses?: {sha, at}, mergify_queue?: {sha, at}}`).
- Client `pr_record_gh_note` (`bin/lib/pr-record.sh`). A failed POST writes `gh-note <repo>#<n> kind=<k> put=failed` to `logs/pr-record.log`.
- `pr_record_statuses` and `pr_record_mergify` answer the miss word `empty` for a marker of the head that is 0..`PR_RECORD_FIELD_MAX_AGE_S` seconds old. A real value always wins. The seams serve `empty` as `{"statuses":[]}` or as `hit-rc:1`.
- `sdq_payload_last` writes the chosen comment to `SDQ_PAYLOAD_COMMENT_OUT` when that is set. Its stdout and rc do not change.
- `PR_RECORD_NOW` (epoch seconds) is a test seam for the marker clock.

## Check on the hub

```bash
grep ' PRR_MISS ' logs/prr-shadow.log | grep -E 'lane=(pipeline-health|dequeue-watch)' \
  | sed -E 's/.*lane=([^ ]+) key=[^ ]*(:[a-z]+) why=([^ ]+).*/\1 \2 \3/' | sort | uniq -c
grep -c 'put=failed' logs/pr-record.log
```

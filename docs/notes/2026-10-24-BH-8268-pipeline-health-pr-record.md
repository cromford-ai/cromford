# BH-8268: pipeline-health reads the fleet's PR record before GitHub

Doc: DB-COORDINATION-SPEC

## What changed

`bin/pipeline-health.sh` now asks the fleet's own PR record (`pr_records`, BH-8067)
first for the two per-PR reads the record can answer. It reads GitHub only on a miss.
The new lib is `bin/lib/ph-pr-record.sh`. It uses the read rule and the helpers of
`bin/lib/pr-record.sh`, but it never calls GitHub itself: on a miss the lane runs its
own old read, so a miss gives exactly the old behavior.

| Section | Old read | Now |
|---|---|---|
| sweep should have landed | `prt_read` (`GET repos/S/pulls/N`) | record `state head_sha`, and `mergeable_state` when the state is `open`. A `merged`/`closed` row writes the `pr-terminal` marker in the `prt_read` format. An open row with a null `mergeable_state` is a miss, never CLEAN. After a fallback read the GitHub answer is written back to the record (source `github`). |
| stale dequeue (BH-3480) | `gh api repos/S/pulls/N --jq .head.sha` | record `head_sha`. No write-back (the old read returns only the sha). |

## The miss line

Each fallback read appends one line to `logs/pipeline-health.log`:

```
<UTC> PRR_MISS <owner/repo>#<n> why=<no-row|stale|no-field|unreadable>[ field=<f>]
```

- `no-row`: the record has no row for the PR.
- `stale`: `age_s` is over `PR_RECORD_MAX_AGE_S`, `age_s` is missing, or the knob is 0.
- `no-field`: a requested field that a GitHub read fills is null (`field=` names it).
- `unreadable`: no jobs client, the GET failed, or the answer has no `row` object.

Count them: `grep -c ' PRR_MISS ' logs/pipeline-health.log`.

## The knob

`PR_RECORD_MAX_AGE_S` (default 900, `catalog/lanes.d/_lib.pr-record.json`), the same
knob `pr_record_get` uses. No second knob was added. Set it to 0 to turn the record
reads off: every read misses with no jobs request, and the lane makes its old reads.

## Reads left on GitHub, and why

- The open-PR lists (`ph_open_list`, `ph_open_rows`, `harness_pr_list`): the worker has
  no list route, and the record has no PR created time, title, author or default branch.
  A record list also cannot prove that a PR with no row is not open.
- `commits/SHA/status` (lead merge unqueued): it reads the `lead-verdict` commit status.
  No record writer stores commit statuses.
- `pulls/N/reviews` (lead merge unqueued): it needs each review's commit id. The record
  holds one `review_decision` word.
- `issues/N/comments` (stale dequeue payload, stall alerts): the record does not store
  Mergify's payload or ticket-issue words. `queue_state` holds only the fleet's own requests.
- `commits/SHA` (stale dequeue head time): the record has no commit time.

A later wave-2 ticket must store the `lead-verdict` status and the review commit ids
before those reads can move.

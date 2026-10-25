# BH-8269: dequeue-watch reads the fleet's PR record before GitHub

Doc: DB-COORDINATION-SPEC

## What changed

`bin/dequeue-watch.sh` now loads `bin/lib/ph-pr-record.sh` (BH-8268). In
`dqw_gather_pr` (`bin/lib/dequeue-watch/gather.sh`), the per-PR read
`GET repos/<slug>/pulls/<n>` goes to the fleet's own PR record (`pr_records`,
BH-8067) first. The lane asks the record for `head_sha`, `head_ref` and
`mergeable_state`. These are the three fields the old read used.

On a miss, the lane runs its old GitHub read, unchanged. Then it writes the
GitHub answer back to the record (source `github`, best effort, rc ignored). The
next tick reads that row from the record.

The lane's decisions do not change. The record values go into the same three
variables that the GitHub read set. A null `mergeable_state` in the record is a
miss, never `-`, because `dqw_classify` turns `dirty` into `textual-conflict`. A
`head_sha` that is not a string is a miss (`why=no-field field=head_sha`).

If the lib does not load, the lane reads GitHub as before (fail-open).

## The miss line

Each fallback read appends one line to `logs/dequeue-watch.log`:

```
<UTC> PRR_MISS <owner/repo>#<n> why=<no-row|stale|no-field|unreadable>[ field=<f>]
```

Count the misses: `grep -c ' PRR_MISS ' logs/dequeue-watch.log`

`ph_prr_miss` takes its log name from `PH_PRR_LOG` (default `pipeline-health`).
A value that is not `[A-Za-z0-9._-]+` is ignored, so the name is never a path.
`bin/pipeline-health.sh` sets no `PH_PRR_LOG`, so its lines stay in
`logs/pipeline-health.log`.

## The knob

`PR_RECORD_MAX_AGE_S` (`catalog/lanes.d/_lib.pr-record.json`, default 900). A row
older than this is a `stale` miss. Set it to 0 to switch the record off: then no
record request is made and every read goes to GitHub as before. This change adds
no new knob.

## Reads left on GitHub

| # | Read | Why it stays |
|---|---|---|
| R1 | `pulls/<n>` | moved: record first, GitHub on a miss |
| R2 | `issues/<n>/comments` (Mergify payload, `sdq_payload_last`) | the record stores no comment bodies |
| R3 | `issues/comments/<cid>` (payload body) | the record stores no comment bodies |
| R4 | `pulls/<m>/files` | not a record column |
| R5 | `commits/<head>/status` (lead-verdict context) | no record writer stores commit statuses |
| R6 | `actions/runs`, `contents/<suite>`, `gh run view --log-failed` | repo-level, not per PR |
| L1 | `issues?labels=merge-queue` and `labels=dequeued` | the record has no list route, and a `dequeued` label fires no webhook wake |

These reads log no `PRR_MISS` line, because they are not record misses.

R3 is redundant: `sdq_payload_last` already reads the full comment list, and
gather then reads the same comment again by id. That is one extra GitHub call per
dequeued PR per tick. `sdq_payload_last` is shared with merge-conductor and
pipeline-health, so this change leaves it. It is a candidate for a later ticket.

## Staleness

A hit is the record as of the last webhook, at most `PR_RECORD_MAX_AGE_S` old. If
a `synchronize` webhook is lost, the lane can see the old head for up to 900 s.
The act layer claims per (pr, head, class), so an old-head action is claimed once
and the next live head is a new key.

## Tests

`tests/dequeue-watch-pr-record.bh-8269-test.sh`, with the seam
`tests/fixtures/dequeue-watch/pr-record.bh-8269.sh` (fixture.sh plus a fake of
`GET`/`PUT /api/pr-records`).

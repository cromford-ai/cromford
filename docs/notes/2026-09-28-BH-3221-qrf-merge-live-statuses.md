# The queue-rows merge gate lists live statuses, not the whole table (BH-3221)

Doc: VERIFICATION-MAP

## What changed

- `bin/lib/qrf/merge.sh` (the merge gate of `bin/queue-rows-flip-preflight.sh`)
  no longer sends the unfiltered `GET /api/merge-queue?project=<p>`. Per project
  directory it reads `?project=<p>&status=queued&limit=500` and
  `&status=blocked&limit=500`, the way `bin/lib/qrf/build.sh` reads the build
  queue. `queued` and `blocked` are the merge queue's live statuses
  (`MERGE_TRANSITIONS` in `worker/jobs/src/lib/core.js`).
- Why: the worker keeps `landed` and `dropped` rows. The unfiltered list for
  cromford came back at exactly its default limit of 200, and `qrf_list`
  fails a list at its limit as possibly incomplete. On the hub on 2026-09-28
  the gate printed `incomplete: rows=200 = limit 200` and could never be READY.
- The route has no offset or cursor, so nothing can be paged. A live status
  that comes back with 500 rows fails as `incomplete: rows=500 = limit 500`.
  A failed or incomplete read of either status skips that project's parity
  (`not checked`), never an empty list.
- A file whose row is `landed` or `dropped` now reads `has no row` rather than
  `has row status landed, want queued`. It is still a FAIL with the same
  `merge_queue_put` fix.
- The no-project-directory liveness probe (`?status=queued`) is unchanged.

## Follow-up: the reader has the same truncation

`mq_queue_list` in `bin/merge-queue.sh` still calls `merge_queue_list <p>`
(`bin/lib/jobs/queue.sh`) with no status and no limit, so under
`merge_queue_rows_only=1` it would get the 200 OLDEST rows, mostly terminal for
cromford, and could miss newer `queued` rows. The gate no longer mirrors
that call byte for byte. The reader needs the same live-status read before the
knob is flipped. That change is to the live merge conductor and is not in this
ticket.

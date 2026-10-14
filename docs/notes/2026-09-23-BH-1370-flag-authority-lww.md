# Pause flags reconcile last-writer-wins on mtime, and the watermark is gone

Doc: DB-COORDINATION-SPEC

## What changed

`flag_sync` in `bin/lib/jobs/flags.sh` used to apply a `pause_flags` row ONCE:
it recorded the row's `updated_at` in `state/flags-db/<name>` and skipped any
row it had already seen. That is the outage in §2.3 row 7 of
`docs/audit-sources/audit-cron-vs-db.md`: the console sets `paused-project-3`
(row @T1), the box applies it and records T1, an operator `rm`s the file, and
the row still reads active@T1, so it is never applied again. The console shows
paused and the box builds.

Now the reconcile compares the row's `updated_at` with the file's mtime, and the
row wins ties:

| row | file | action |
|---|---|---|
| active | absent | create, mtime = the row's `updated_at` |
| active | present | nothing (re-touching would churn the mtime) |
| inactive | present | remove iff `row_epoch >= file mtime`, else keep |
| inactive | absent | nothing |

Four answers are non-actions that never touch `flags/`: an outage (rc 1), no row
(rc 2, a 404), a row with no readable `active`, and an `updated_at` that is not
the worker's `YYYY-MM-DDTHH:MM:SS[.fff]Z` shape (GNU `date` parses `yesterday`
and the empty string, so the shape is checked first). The last two return rc 1
and leave one line in `logs/jobs-client.log`.

## The stamp

A file the reconcile creates carries the row's time (`touch -d @<epoch>`), and
`flag_set` stamps the PUT response's `updated_at` onto the file it just wrote.
Without that, a file the sync wrote would have mtime "now" and no later row
could ever beat it, so console resume would be dead on arrival. With it a file
and its row are equal, and a local `touch` (autohalt, an operator) is newer than
the row and survives until a row written after it.

`state/flags-db/` is no longer read or written. A directory left on a box is
inert.

## The readers

Five sites that tested the bare file now go through `flag_active`, with the file
test as the else-branch for a box whose `bin/jobs-client.sh` is missing:
`bin/merge-queue.sh` (`automerge-disabled`), `bin/lander.sh`
(`automerge-disabled`, `lander-disabled-<project>`), `bin/rebase-train.sh`
(`automerge-disabled`), `bin/rebase-train-ahead.sh` (`rebase-train-off`,
`automerge-disabled`) and `bin/lib/mc/classify.sh` (`merge-conductor-actions`,
`automerge-disabled`). A sixth, `bin/tier2-merge-sweep.sh`, was retired on main
by BH-1366 before this landed. In `rebase-train.sh` and `rebase-train-ahead.sh`
the client is now sourced before the kill switch, or `flag_active` would never
be defined there.

## The residual

The row is worker-stamped and the mtime is box-stamped. The common path never
compares across clocks (the stamp makes them equal). A box ahead of the worker
keeps its own local touch against a newer row; a box behind loses a local touch
to a stale row. Bounded by `bin/clock-sync.sh` and `bin/lib/tz-check.sh`, which
both page.

No knob: this changes an existing reconcile in the direction the ticket asks,
is fail-identical under a worker outage, and a knob read through the flag system
it gates would be circular.

Pinned by `tests/flag-authority.bh-1370-test.sh`.

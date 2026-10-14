# The console /merge-queue screen (BH-3158, BH-2325.3)

Doc: MERGE-CONDUCTOR

## What changed

The console has a read-only `/merge-queue` screen. You reach it from the MERGE
QUEUE button in the Kanban header, and the KANBAN tab stays lit while you're on it.
It shows three things:

- **MERGE QUEUE.** The `merge_queue` rows for the queued, blocked and dropped
  statuses, oldest first. There's one read per status, and landed rows are
  never read. `?project=` filters those three reads.
- **HELD PAGES.** What `GET /api/conductor/held` returns, with each PR linked to
  GitHub. The count is the worker's `n_total`.
- **RECENT CONTROL CHANGES.** The `config_changes` rows of kind `merge_queue` and
  `held_page`, newest first.

A banner above the tables says what the `merge_queue_rows_only` settings row
means for the boxes. The copy follows `bin/lib/jobs/queue.sh`
(`merge_queue_rows_only_on`) and `bin/merge-queue.sh`. With no row, each box
uses its own `MERGE_QUEUE_ROWS_ONLY` env, and the console can't see that, so the
banner says so rather than saying "off".

## Why

Before this, the only way to see the queue or the held pages was a box shell,
the conductor log or the bearer-gated API. The read-only screen comes first, and
the actions follow in the sibling tickets.

## What it does not do

It changes nothing in how the queue or the conductor decide, and it adds no worker
route or schema. The row actions and the release button are the BH-3155
contract stubs in `console-ui/src/screens/merge-queue-actions.js`, and they
render nothing until the actions sibling lands. A failed read shows as an error
or a footnote, never as an empty queue. A status read that comes back at the
500-row limit says its newest rows are missing, because the worker orders by
`enqueued_at` ascending.

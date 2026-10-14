# 2026-09-23 — BH-1610 (BH-1595.3): reconcile-prs remembered answers move to D1

Doc: worker/jobs/README.md

**What changed.** What reconcile-prs learns about PRs used to live only in the owner
box's files under `state/reconcile-prs/{open,terminal,gone}`. It is now also kept in
D1 `reconcile_memory` through `GET`/`PUT /api/reconcile-prs/memory`, so a box that
becomes the owner starts from what the last owner learned. Before this, it paid one
single-PR read per remembered PR. `failed/` stays file-only.

**How it works** (`bin/lib/reconcile-read.sh`).
- `rcr_tick_begin` calls `rcr_memory_hydrate`. It GETs the table and writes each row
  to its file: `terminal` and `gone` as they are, `open` as max(file, row). When the
  GET answered in full (`truncated: false`), every local file with no row is sent up
  too. That covers the one-time migration and anything a lost flush never delivered.
- Every change to one of those files is journalled to `$RCR_TICK/journal.jsonl`:
  `_rcr_open_mark`, `rcr_remember_terminal`, the drop in `_rcr_cached`,
  `rcr_gone_record`, `rcr_gone_clear` (only when a backoff existed) and `rcr_prune`.
  A write that leaves a file unchanged is not a change and is not journalled.
- `rcr_memory_flush` (once per tick, from `bin/reconcile-prs.sh`) keeps the last
  change per `(kind, name)` and sends it as one PUT, chunked at 500 entries. Before
  sending, it drops anything the worker would refuse, with one log line.

**Failure.** D1 never decides a classification. A failed GET is one
`memory GET failed` line in `logs/reconcile.log`, and the tick runs on the files.
A GET that answers with no `rows` array also counts as failed, not as an empty table.
A failed PUT is one `memory flush failed` line. The unsent changes go to
`state/reconcile-prs/journal.pending`, get re-sent next tick, and their keys win over
the D1 rows at that tick's hydrate. A 400 is dropped, not kept, because re-sending
a body the worker refused would fail on every tick.

**Worker rules.** At most 5000 rows per GET, with `truncated` measured from a 5001st
row. At most 500 entries per PUT. Names are `[A-Za-z0-9._-]{1,128}` and not only dots,
because a name becomes a file name on the box. Values are 1-4096 chars. One bad entry
is a 400 for the whole body. The writes run in one `DB.batch`, and `open` only
ever moves forward.

**Check it.** `bash tests/reconcile-prs-d1-memory.bh-1595-test.sh`;
`cd worker/jobs && node --test test/routes/reconcile-memory.bh-1595.test.js`.
After deploy: `curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/reconcile-prs/memory" | jq '{n:(.rows|length),truncated}'`
answers 200 (not 503 `reconcile_memory schema not applied`).

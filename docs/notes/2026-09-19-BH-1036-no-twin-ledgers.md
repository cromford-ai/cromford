# The six file-only idempotency markers get a row twin, behind one flag

Doc: DB-COORDINATION-SPEC

BH-1036 is slice 11 of the state→DB epic (#1028). Six hub/box file stores were
the ONLY record that paid or client-visible work had already happened. All six
live in `state/` on one machine, so a hub wipe — or the same build re-offered to
a different pool box — makes every one of them answer "never seen it": a second
adversarial review is dispatched (under a daily cap that reads zero), a second
lander session is bought, a train member that was already closed is commented on
again, a production QA drive runs twice, and a ticket held after two malformed
plans buys a third plan.

The ticket named a seventh, `state/migration-prs-alerted.txt`. It is not in this
change: BH-1040 landed first and already made `ledgers(kind=migration)` that
lane's record, with its own three-way read (seen / miss / unknown → hold and
alert), a legacy-file back-fill and a deliberate write-AFTER-send. Twinning it
again under a second kind would put the same fact in two stores that cannot see
each other, under two different write orders — so `bin/check-migration-prs.sh`
is untouched here and keeps BH-1040's store.

No schema change. The rows go in the EXISTING `ledgers` table
(`worker/jobs/schema.sql`, PK `(kind, key)`, verbs `job_ledger_get` /
`job_ledger_put`), which already carried this exact shape for `pr_merged` and
`plan_malformed`. The overlap-defer twin is not a row at all — the deferring
build already writes an `overlap_defer` artifact, so the reader just reads it
back.

## The library, `bin/lib/ledger-twin.sh`

Sourced, never executed. Five verbs, and the asymmetry between them is the
whole design:

- `lt_on` — rc 0 when the `no-twin-ledgers` flag is up. Through `flag_active`
  when `bin/jobs-client.sh` is sourced (that is what reconciles the flag from the
  DB), otherwise a plain test of `flags/no-twin-ledgers`. **Resolved once per
  process**: `flag_active` talks to the worker on every call, and the candidate
  loops below it — one per open PR, one per train candidate — would otherwise buy
  a request per row for an answer that cannot change inside one lane run.
- `lt_get <kind> <key>` — `job_ledger_get`'s rc contract verbatim: 0 prints the
  status, 2 is a real miss, 1 is "unusable" (flag off, no client, worker down).
- `lt_read <kind> <key>` — the same read for the callers that want the VALUE,
  into `LT_VAL` instead of stdout. It exists because the breaker below can only
  latch in a shell that outlives the call, and `$(lt_get ...)` is not one.
- `lt_seen <kind> <key>` — rc 0 when a row exists, whatever its status.
- `lt_put <kind> <key> <status> [detail]` — **always rc 0.**

A READ that cannot be answered is never "already done": the lane falls back to
its file and, at worst, does the work a second time. A WRITE that cannot be made
is not a failure: the file line is already on disk, so no lane may exit non-zero
because the side channel blinked. Every verb is a no-op when the client was not
sourced, and each of the six lanes carries a one-line fallback definition so a
box mid-sync — the script landed, the library not yet — behaves exactly as it
does today.

**One outage per process, not one per candidate.** A worker that REFUSES is
cheap — the client returns at once. A worker that HANGS costs `JOBS_TIMEOUT` x
retries on every call, and these verbs sit in per-candidate loops, so a single
hung worker turns an hourly flock'd lane into a lane that does not finish its
tick. The first unusable read (`lt_read`/`lt_seen` rc 1) or failed write latches
the library off for the rest of the process. The direction is the documented
fail-open one: latched off, a read is rc 1 and never "already done", and a write
is rc 0 with the file line already on disk. A real miss (rc 2) never latches —
the worker answered. The latch lives for one process; the next tick asks again.

## What each lane does now

`bin/review-autopilot.sh` — the head marker check at the top of the loop is
`[ -f "$KEY" ] || lt_seen review_autopilot "$SLUG#$NUM@$HEAD12"`; both marker
writes (the review-prs stand-down and the posted review) gain an `lt_put` AFTER
the `printf > "$KEY"`. The daily cap reads `max(file, row)` — the HIGHER count
wins, because a row that reads low is what would buy a 41st review — and the
count write gains an `lt_put review_autopilot_cap "<project> <YYYYMMDD>"`.

`bin/lander.sh` — the one-attempt-per-head mark also asks
`lt_seen lander "$PROJECT#$NUM@$HEAD"`; the mark write gains an `lt_put`, still
before the worktree and before `agent-call.sh`.

`bin/batch-resolve.sh` — a new `member_excluded <num> <head> [only-status]`
helper next to `say()`. It greps the three per-member files first and asks
`lt_get batch_member` only when they have nothing. The candidate filter's three
greps became one call; the settle's idempotency guard became
`member_excluded "$num" "$head" landed`. The `only-status` argument exists
because the settle asks a narrower question than the filter: **a `red` row must
not satisfy a `landed` guard.** All three appends gain an `lt_put`.

`bin/run-build.sh`, `# >>> overlap not-before` — when the marker file is absent
and the flag is up, `job_artifact_feed overlap_defer <project> <now-1h> 500` is
read, filtered to `ref == deferred` and `ticket_id == $KEY`, newest first, and
`updated_at + detail.not_before_s` becomes the not-before. The same RESULT string
and the same `exit 3`; no file to consume on that path. **The cap cannot hide a
live deferral** — the window asked for is an hour and the fact's own lifetime is
`OVERLAP_DEFER_NOTBEFORE_SECS` (default 600s), so a row that falls off the end
has already expired. A `proceeded` artifact carries no `not_before_s` and is
ignored.

`bin/run-build.sh`, `PM_HOLD_STATUS` — the read ORDER flips. With the flag up the
row is the record and the file is the cache behind it; with it off, the file is
the box's word and the ledger answers only when the file has no row, which is
exactly today. Reading the ticket's "drop the file half" the other way — deleting
the file read outright — would break an operator's file-only `released` row with
no cycle in which to notice, so the file write stays for this cycle.

`bin/postmerge-qa.sh` — `already_done` greps the file then asks
`lt_seen postmerge_qa "$BK"`; `mark_done` appends the file then writes the row
with the verdict as its status and the merge sha8 as detail. The header comment
was corrected in the same commit: it promised a coordination-row ledger that
stopped a build being driven twice, and the row that actually does that is this
one (D5).

`bin/check-migration-prs.sh` — **not touched.** The planned
`migration_pr_alerted` twin was dropped on review: BH-1040 already owns this
lane's dedupe as `ledgers(kind=migration)`, and its write-after-send order is
deliberate (a run killed mid-send must not leave "alerted" behind for a page
that never went out). Two kinds for one fact is a dedupe neither half can see.

## It ships dark

```bash
bin/jobs-client.sh flag-set no-twin-ledgers on "BH-1036 cycle 1"
```

With the `pause_flags` row absent every lane is byte-for-byte what it is today
and no ledger row is read or written. The one request a dark lane still makes is
`flag_active`'s own reconcile of `flags/no-twin-ledgers`, which is how every
DB-backed flag in the fleet works and is what makes the flag flippable from the
hub at all.

## What was deliberately NOT done

- **No backfill.** Pre-existing file-only markers are not written into rows; the
  file still answers them. The cycle that deletes the file reads owns a one-shot
  backfill, and doing it here would add N writes per tick per lane for a fact the
  file already has.
- **No new table.** The ticket offered "`ledgers` kinds or `pr_attempts` kinds";
  there is no `pr_attempts` table in `worker/jobs/schema.sql`, and adding one is
  a schema change the ticket does not require.
- **`state/batch-resolve/train-*.json` is left alone.** It is a train record, not
  membership: it already has its `pr_merged` row and the conductor's hold files.
- **The pre-post review caching and the `reviewed-unposted` / `empty-terminal`
  statuses stay in #1018.** The status vocabulary here (`reviewed` / `skipped`)
  matches the file's own first token so #1018 can add to both halves without
  renaming anything.
- **`mc_autopilot_verdict`'s file mirror read** in `bin/lib/merge-conductor-lib.sh`
  keeps reading the file, which is still written.

## How it is proven

```bash
HARNESS_TEST_SANDBOX=1 bash tests/no-twin-ledgers.bh-1036-test.sh
```

Eight sections, 96 assertions. Section A drives the library against the real
`bin/jobs-client.sh` with a curl shim. Sections B–H each drive the REAL shipped
lane (or, for `bin/run-build.sh`, the shipped region read through
`tests/lib/rb-all.sh`, the BH-568 seam rule) with an EMPTY state directory and
populated rows, and assert that the thing which costs money never happened: the
`agent-call.sh` sink is absent, no `gh pr comment`, no `issues/<n>/comments`
POST, no browser drive, no `beat.sh`, no plan session. The negatives carry equal
weight and are in every section: a row at a different head, a `red` row against a
`landed` guard, a neighbouring ticket key (`BH-10360` vs `BH-1036`), a ledger
outage, and the flag OFF with every row present.

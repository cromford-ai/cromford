# The once-only comment markers and the resolver's counters are D1 rows

Doc: PR-OWNERSHIP, DB-COORDINATION-SPEC

## What was wrong

Four client-visible comments are posted once and guarded by a marker file under `state/`:

- the BUILD BLOCKED notice (`bin/lib/rb/execute.sh`, `state/blocked-commented-<p>-<KEY>-<build>`);
- the tier-1 "Merged in …" close (`bin/lib/rb/pr.sh`, `state/merge-close-commented-<slug_>-<n>`);
- the split parent's close (`bin/decompose-parent-close.sh`, `state/parent-close-commented-<p>-<N>`);
- the resolver's rebuild-outcome comment (`state/blocked-resolver/<p>/<ck>.rebuild-commented`).

A wiped or rebuilt box lost them and posted the comment again. The re-offer paths
(`bin/blocked-resolver.sh` `br_enqueue_fresh`, `bin/pr-owner-sweep.sh` `handback`) had to
`ssh root@<box> rm -f …` to clear a stamp on another machine. The resolver's per-ticket record
(`state/blocked-resolver/<p>/<ck>.json`) was file-only too, so a wiped hub forgot an ABANDONED
ticket and ran its ladder again.

## What changed

- `bin/lib/comment-mark.sh` (`cm_has`, `cm_put`, `cm_clear`). Each marker is also a
  `ledgers` row: kind `commented`, key `blocked <p> <KEY>`, `merge-close <owner/repo> <n>`,
  `parent-close <p> <N>` or `rebuild <p> <ck>`, status `commented` (detail = the token: the build
  basename for `blocked`, `-` otherwise) or `cleared`. The read rule:
  - `cleared` means not marked, even with a stale file left somewhere;
  - `commented` with the same token means marked;
  - anything else (another token, an unknown status, no row, an outage, no client) is answered
    by the file, so it is exactly the old answer.
- The write order of each marker is unchanged: `blocked`, `merge-close` and `parent-close` still
  write only after the POST landed, and `rebuild` still writes before the send.
- The re-offer clears the `blocked` row first. When the jobs DB takes that write, nothing is
  ssh'd. The ssh rm (and the local rm) is only the outage path. `pr-owner-sweep` DRY-RUN now says
  `would: clear row blocked <p> <KEY>`.
- `bin/jobs-client.sh` gains `job_ledger_row <kind> <key>`: the status and the detail as one
  JSON line (rc 0), rc 2 on a real miss, rc 1 on an outage.
- `bin/blocked-resolver.sh` `br_save` is the one write of a ticket record: the file first, then
  a `ledgers` row kind `br_record`, key `<p>/<ck>`, status the outcome (`open` when empty),
  detail `{rebuilds,fixrounds,mechanicals,regens,adjudications,rereviews,first_seen}`. Every
  record writer goes through it. `br_load` restores that shape (`restored:"ledger"`) when the
  file is missing and the row answers rc 0. A file on disk always wins, so the documented
  un-park (set `.outcome` to `""` in the json) still works. A miss is read once per tick
  (`BR_ROW_MISS`).

## What did not change

- `attempts[]` and the guard fields stay file-only. A wiped hub does not rediscover parks from
  rows; it restores a record when a candidate source names the key.
- `bin/unblocked-children.sh`'s `<C>.commented` marker is untouched.
- No schema change: `ledgers` already exists (`worker/jobs/schema.sql`).

## Probe after deploy

- `bin/jobs-client.sh ledger-get commented "merge-close example-org/cromford <n>"` after the
  next tier-1 merge shows a row.
- `grep 'ssh root@' logs/pr-owner-sweep.log` has no `blocked-commented` line after the first
  handback.

Tests: `tests/comment-mark.bh-2317-test.sh`, `tests/blocked-resolver-record-rows.bh-2317-test.sh`.

# Blocked resolver reads builds of record from the ledger (BH-2312.2)

Doc: MERGE-CONDUCTOR

`bin/blocked-resolver.sh` now sources `bin/lib/builds-of-record.sh` (BH-2347) and reads the jobs
ledger before it globs `builds/`. Both of its record-reading sources used to see only the RESULT
files on the hub. A build whose record never reached the hub was invisible to them.

**Rebuild candidates (`br_from_builds`).** For each `fleet-conf.sh --projects` project (`$ONLY`
respected) it reads `bor_union`. It adds a row only when the row is ledger-only: it has a job id,
and `bor_local_dir` finds no dir. That row goes through the same RESULT-line `case`, the same
90-minute floor and the same 6-hour review backstop, all aged from the ledger `updated_at`. Its
record is `-` and its url is `-`, the same shapes the queue source and the glob already emit. So
`br_rebuild_fresh`'s caps, in-flight wait and ordering are unchanged, and no ledger `pr_url` is
closed by this source. The glob loop over local dirs is unchanged, and a ledger row that has a
local dir stays the glob's, markers included, so no record is offered twice. A ledger-only
`ABANDONED_TIMEOUT` is never a candidate, because only a local dir can carry `REAPED` (BH-1770).

A ledger-only row has no dir that could carry `.blocked-resolver-superseded`, so the ticket's own
state file `state/blocked-resolver/<p>/<rkey>.json` stands in for it. The row is skipped when its
build_dir (bare, `pool-` or `fly-`) is in `.rebuild_seen`. It is also skipped when the last ladder
attempt (hold and stall lines excluded, as `br_from_rebuilds` reads them) is at or after the row's
`updated_at`, because then the resolver has already acted on that park. An unreadable state file
or timestamp skips the row.

**The ticket-merged guard still runs for a ledger-only park.** `br_already_merged` only asks GitHub
whether the ticket merged once `br_park_time` can date the park. A ledger-only park has no RESULT,
and a build that never touched the hub usually has no queue row or state file either. Before this
fix it went undated, the guard answered "not merged" without a search, and the ladder rebuilt it.
That is the 2026-09-14 failure again. `br_park_time` now dates a park whose record is `-` from the
newest ledger row for `<project>-<KEY>-`, checked after the queue rows and before the state file.
When the ledger does not answer (rc 1), the date is unknown (rc 2), and `br_already_merged` returns
its own unknown. No rung is taken that tick.

**Expect a backlog on the first ticks.** Ledger-only admission has only a minimum age (90 min, or
6 h for REVIEW_BLOCKED), and `bor_union` can return up to `BOR_LIMIT` rows per project. So the first
ticks after deploy may offer old parks the hub never saw. Each one costs one merged-PR search, and a
ticket that merged later resolves `resolved-merged` without a rebuild. `PER_TICK` and the rebuild
caps still bound how many rungs a tick takes.

**Rebuild outcome (`br_from_rebuilds`).** When `bor_union` answers rc 0 or 2, the poll reads the
rows whose build_dir starts with `<project>-<KEY>-` (the dash keeps `BH-23` from matching
`BH-234`). It compares the ledger `updated_at` with the attempt's `at` instead of the RESULT mtime.
A local-only row's `updated_at` is that mtime, so local-only records behave as before. The
superseded and abandoned markers still apply when a local dir exists, and the seen filter matches
the dir name and the bare, `pool-` and `fly-` build_dir. When a local dir has a RESULT, its line 1
wins over the ledger's copy, because `bin/pr-url-reconcile.sh` rewrites it in place. The ledger is
read once per project per call.

**Outage.** When `bor_union` answers rc 1, or the lib is missing, both sources run exactly the
glob they ran before. An outage never reads as "no records".

Operator check on the hub: `grep -E 'fresh rebuild landed|rescue-giving-up|pr-create-failed'
logs/blocked-resolver.log`, and `jq .rebuild_seen state/blocked-resolver/<p>/<key>.json`.

Tests: `tests/blocked-resolver-db-first.bh-2312-test.sh`.

# The rebuild ledger's contract: row fields, `queue_row`, and two key-cache hooks

Doc: MERGE-CONDUCTOR

**What changed.** BH-487 is split in three; this is order 1 of 3, the contract.
It adds the shapes the other two write into, and it changes what no tick does.

- **NEW `bin/lib/rebuild-ledger.sh`**, sourced by `bin/blocked-resolver.sh`.
  Four real functions on the resolver's state row — `br_job_add` (append
  `{id,enqueued_at,at}` to `rebuild_jobs[]`, deduped on `id`), `br_jobs_count`,
  `br_jobs_why` (the `" (jobs: a, b)"` suffix for the ABANDONED alert) and
  `br_set_wait` (`wait`/`wait_job`, never `outcome`) — plus two stubs,
  `br_tkey_put` and `br_tkey_sync`, whose bodies land with the ticket-key cache.
  The lib resolves no harness root of its own: `br_file`, `br_load`, `STAMP` and
  `$ST` are the resolver's and bind at call time, the same arrangement
  `bin/lib/hold.sh` uses.
- **`bin/jobs-client.sh` gains `queue_row <project> <key>`** and the `queue-row`
  CLI verb next to `queue-status`. One TSV line — status, enqueued_at,
  claimed_by, requested_by, reason — with `-` for every absent field so a
  malformed row cannot shift the columns. rc 0 the row, rc 2 the worker answered
  and there is no row, rc 1 an outage.
- **`bin/blocked-resolver.sh`, three lines.** The lib is sourced HARD, the way
  `merge-conductor-lib.sh` is; `br_one` calls `br_tkey_put` where it derives a
  key discovery did not carry; `br_conductor_emit` passes its key through
  `br_tkey_sync`. Both stubs are no-ops here, so every row the lane emits and
  every rung it takes is byte-for-byte what main does.

**Why.** `rebuilds: N` answers "how many" and nothing else — not which job, not
whether one is still running, not what to print when the ladder gives up. The
rung that waits on a queued rebuild (BH-487.1) needs the job's identity, and the
key cache (BH-487.2) needs somewhere to put a key that cost a `gh` call. Both
are cheaper to review against a contract that is already merged than as part of
the change that uses it.

**Absent is not zero.** `br_jobs_count` prints `null` for a row with no
`rebuild_jobs` key at all — a row written before this landed, which keeps
counting on `rebuilds` — and `0` for a present-but-empty ledger. jq's `//`
treats `[]` as present, which is the whole reason the function reads
`(.rebuild_jobs // null)` and not `(.rebuild_jobs // [])`. Collapsing the two is
how an already-capped ticket buys one more rebuild.

**Why the source is hard, and what it cost.** A soft `[ -r ] &&` guard on a box
whose `bin/lib/` has not synced leaves the resolver running its ladder with
`br_jobs_count` undefined — silently back on the bare counter once BH-487.1
reads it. So the lane prints one stderr line naming the lib and exits 1 instead.
Six suites `cp` the resolver into a scratch `$H/bin/` and execute it, and a hard
source exits 1 in every one of them, exactly as `merge-conductor-lib.sh` already
does. Each of those six gained ONE fixture line copying the new lib
(`tests/blocked-resolver-test.sh`, `tests/blocked-resolver.bh-541-test.sh`,
`tests/blocked-resolver.bh-614-test.sh`, `tests/resolver-hold-test.sh`,
`tests/conductor-sticky-handoff-test.sh`, `tests/no-harness-export-test.sh`).
No case was added and no assertion changed in any of them.

**What it touches.**

- State: `state/blocked-resolver/<project>/<project>-<KEY>.json` may gain
  `rebuild_jobs[]`, `wait` and `wait_job`. Nothing on this branch writes them.
- Knobs: none. No new `BR_*` env var. `REBUILD_WAIT` is a schema value, not a
  tunable.
- CLI: `bin/jobs-client.sh queue-row <project> <KEY>`, and the usage string.
- Log lines: only the new refusal, `blocked-resolver: bin/lib/rebuild-ledger.sh
  missing — cannot read the rebuild ledger`, on stderr.

**Still owed.** The writers. `br_job_add`/`br_set_wait` are called by nothing
until BH-487.1, and the two `br_tkey_*` stubs do nothing until BH-487.2. Both
stack on this branch. Everything above is proven by
`tests/rebuild-ledger.bh-946-test.sh`, which drives the real lib in process, the
real `bin/jobs-client.sh` through its CLI verb against a stubbed transport, and
the real `bin/blocked-resolver.sh` end to end from a scratch `$HARNESS` — the
hard source by deleting the lib and reading the exit code, the two hooks by
replacing the lib with a recorder.

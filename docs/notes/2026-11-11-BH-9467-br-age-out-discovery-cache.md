# Resolver ages out old rows with no open PR, reads only changed paths in discovery, and hands off a fresh park while SATURATED (BH-9467, slice C1 of #9369)

Doc: MERGE-CONDUCTOR

## Problem

On 2026-11-09 the hub's cromford tick of `bin/blocked-resolver.sh` found `candidates=783`, ran `rungs=2/100` and stopped on `reason=tick-budget` after 1959 s. Discovery alone took 906 s (`discovery_src=rebuilds:416,conductor:34,builds:403,reviews:52`, in seconds). Two causes are in this slice:

1. `br_prepass` dropped a row only on a closed PR (C0) or a finished record. A build or rebuild row of a ticket that nobody works on stayed a candidate for ever.
2. `br_from_builds` read every build dir's RESULT, and `br_from_rebuilds` read every open record, on every tick. They took the same decision as the tick before.

## What changed

1. **Age-out** (`bin/blocked-resolver.d/bh-9467-record-age-out.sh`, one `bra_prepass_row` line in `br_prepass`). A `build` or `rebuild` row leaves the list when all of these are true:
   - Its ticket has no open PR. The row url is not in the open list, and no open head branch names the ticket key. `bh-946` does not match `ticket/bh-9467`. `bh-9369` matches `ticket/bh-9369.1` and `ticket/bh-9369-r2`.
   - Its RESULT and its record are both at least `BR_RECORD_MAX_AGE_DAYS` old. A build row with no record passes on its RESULT. A rebuild row with no dir passes on its record.
   - Its record outcome is not `HELD` or `DATA_LANE`.

   These rows are kept: an open list that does not read (one line per project); a record whose `.updated` does not read; a ledger-only build row (no local RESULT age). The mark is written before the line:
   - A build dir gets `.blocked-resolver-retired` with the word `aged-out`. `br_from_builds` skips the dir from the next tick, and the prof line counts it in `retired_skipped=`.
   - A rebuild record gets one `aged-out` attempt. Its last attempt is then not `rebuild-fresh*`, and `br_from_rebuilds` reads past it. The outcome and the counters do not change. A new `rebuild-fresh*` attempt, or a new build dir, brings the ticket back.

   There is one `resolver_retired … aged out` line per row, once. `br_from_rebuilds` no longer rewrites `rebuild_result` and `wait` when the record already holds those values. Before, that write moved `.updated` on every tick, so a `rebuild-*` row could never be old.
2. **Discovery cache** (`bin/blocked-resolver.d/bh-9467-discovery-cache.sh`, one-line call sites in `bin/lib/br/discovery.sh`). Each source makes one `find` per tick for the current signatures: a build dir is `<dir mtime>:<RESULT mtime>`, and a record is `<mtime>:<size>`. A path with the same signature as the last tick, and a stable decision, is skipped with no read. A stable decision is `skip`, `retired`, or a rebuild `wait` that is younger than `BR_DISCOVERY_RECHECK_MIN`. An emitted row, a time floor or a state read is not cached. Those paths are read again next tick. The cache is `state/blocked-resolver/.disc-cache-<builds|rebuilds>-<project|fleet>.tsv`. It is rewritten whole each tick (tmp + mv) with only the paths seen that tick. A header change discards it with one line: fleet.conf mtime, the project list or `BR_RECORD_MAX_AGE_DAYS`. Each source writes one line: `discovery cache <source>: D path(s), H unchanged and skipped, R read (C cache rows written)`.
3. **One-PR run discovery.** A `BR_ONLY_PR` run does not call `br_from_builds` or `br_from_queue`, because their rows carry url `-` and the run keeps only its PR's rows. `br_from_rebuilds` reads only the records that name the PR url (one `grep -lF`). The run never reads or writes a cache file. One line: `one-PR run for <o/r#n>: builds and queue sources skipped (their rows carry no PR url)`.
4. **ZERO_DISPATCH wording** (`brpf_zero_alert`, the operator on #9369, 2026-11-10). The alert says `<k> undispatched hand-off(s) (<n> dispatched with rc 3)`. The id and the gates do not change.
5. **Fresh park while SATURATED** (`stuck_rekick`, arg 16 `since` from `bin/merge-conductor.sh`). While the resolver is SATURATED, a BLOCKED_HUMAN or RED_TWICE park younger than `MC_SAT_FRESH_PARK_MIN` is handed off again. An older park keeps today's `not re-handed off` line.

## Knobs

| Knob | Lane | Default | 0 means |
|---|---|---|---|
| `BR_RECORD_MAX_AGE_DAYS` | blocked-resolver | 14 days | age-out off |
| `BR_DISCOVERY_CACHE` | blocked-resolver | 1 | cache off: every path is read, no file |
| `BR_DISCOVERY_RECHECK_MIN` | blocked-resolver | 30 min | a rebuild wait is never cached |
| `MC_SAT_FRESH_PARK_MIN` | merge-conductor | 1440 min | no fresh hand-off while SATURATED |

To turn a part off: set its knob to 0, or `BR_OPT_OFF=bh-9467-record-age-out` / `BR_OPT_OFF=bh-9467-discovery-cache`. With the cache fragment off, a one-PR run walks every source again.

Fix 4 (`BR_ROW_MAX_SECS`) is slice C2 (#9468).

## Tests

`tests/br-age-out.bh-9467-test.sh`, `tests/br-discovery-incremental.bh-9467-test.sh`, `tests/br-replay-drained.bh-9467-test.sh`, `tests/br-zero-dispatch-wording.bh-9467-test.sh`, `tests/mc-sat-fresh-handoff.bh-9467-test.sh`.

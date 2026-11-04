# Resolver discovery skips retired rows; a standing verdict decline is not retried; bad records are quarantined (BH-9029)

Doc: MERGE-CONDUCTOR

## Problem

On 2026-11-03 the cromford tick of `bin/blocked-resolver.sh` was
time-bound for 13 ticks in a row (`reason=tick-budget`). The prof lines showed
`discovery=785` to `801` seconds. Three faults:

1. `br_prepass` wrote `.retired=true` on 107 to 109 records each tick, but no
   discovery source read the flag. Each retired row was discovered, read from
   GitHub and dropped again on the next tick. `br_from_rebuilds` forked `cat`
   and two `jq` on each of 2,367 state files before it dropped the finished
   ones.
2. PR #8999 reached rung rebuild-fresh on every tick and ended
   `SUPERSEDE DECLINED (verdict)` each time, at about 330 s a tick.
3. One state record did not parse. Every tick carried `+index-short`, and no
   line named the file.

## What changed

The new logic is in two fragments, `bin/blocked-resolver.d/bh-9029-discovery-index.sh`
and `bin/blocked-resolver.d/bh-9029-decline-mark.sh`. The driver and
`bin/lib/br/discovery.sh` call them with one line at each site.

1. **The discovery index.** Before `br_candidates`, `bdi_load` makes one
   `find | awk | jq` pass over the run's records. It keeps the outcome of each
   record path, and the PR urls of records with `retired=true` and outcome
   `RESOLVED_MERGED` or `ABANDONED`.
   - `br_from_conductor` (both loops) and `br_from_reviews` skip a row whose
     PR url is in that set, before any fork or GitHub read. The key is the PR
     url, not the ticket, so another open PR of a retired ticket (BH-8339) is
     still discovered.
   - `br_from_rebuilds` skips a record whose indexed outcome is finished
     (`RESOLVED_MERGED`, `ABANDONED`, `ESCALATED`, `STALLED`) before the `cat`.
   - A finished `build` row has no PR url, so the pre-pass writes
     `.blocked-resolver-retired` (`<outcome>\t<stamp>`) in its build dir, and
     `br_from_builds` skips a dir with that marker. Line 1 of `RESULT` is read
     with a builtin `read`, not `head`.
   - If the index does not load, one line says so and every skip answers "no":
     the tick runs as before.
2. **Aged retire (the D11 case).** A `RESOLVED_MERGED` record whose row has no
   PR url is retired when its `.updated` is `BR_FINISHED_RECORD_RETIRE_DAYS`
   days old (default 14, 0 = off; registry row
   `lane.blocked-resolver.BR_FINISHED_RECORD_RETIRE_DAYS`). One
   `resolver_retired` event per record says
   `finished with no PR url, untouched for <n> days (BR_FINISHED_RECORD_RETIRE_DAYS=<k>)`.
   The record also gets `retired_aged=true`, because the flag write moves
   `.updated`. A `rebuild-*` reason is never retired this way.
   `br_record_index` has two more columns for this: `age_days` and
   `retired_aged`.
3. **The decline mark.** A `SUPERSEDE DECLINED (verdict)` writes
   `decl_mark {url, head, vhead, vrow, vword, kind, reason, ladder, why, logged}`
   on the record. `br_one` asks `bdm_skip` after the fix-round adoption. While
   the same verdict row with the same word stands on `vhead`, the PR is on
   `head`, the reason and the ladder counters are the same, and the head is
   not in `noop_heads`, the row takes no rung (rc 3). The first skip of an
   episode writes one line:
   `SKIP decline-mark — SUPERSEDE DECLINED (verdict) stands: verdict row <id> on <vhead>, PR head <head>; …`.
   The skip still calls `br_sup_alert`, so the decline page fires after
   `BR_SUPERSEDE_DECLINE_ALERT_SECS`, and it releases a conductor park the way
   the decline did. Any change clears the mark with one
   `decline mark cleared: <why>` line and the row runs. A head or verdict read
   that fails keeps the mark and runs the row as before.
4. **Bad records.** The pre-pass hands the unparseable paths to
   `bdi_bad_records`. The tick line ends ` bad_records=[<paths>]` only on the
   tick where the set of bad paths changes (episode file
   `state/blocked-resolver/.index-bad[-<project>]`). A bad record whose mtime
   is `BR_BAD_RECORD_QUARANTINE_MIN` minutes old (default 10, 0 = name only)
   is moved to `state/blocked-resolver/<project>/.bad/<key>.<stamp>.json` with
   one line. The next tick's `br_load` finds no file and restores the counters
   and outcome from the ledger row (BH-2317). Observe mode says
   `WOULD quarantine`.
5. **The prof line** gains `discovery_rows=<n> retired_skipped=<n>
   discovery_src=rebuilds:<s>,conductor:<s>,queue:<s>,builds:<s>,reviews:<s>,external:<s>`
   before `project=`.

HELD rows are not retired: `br_one` must still re-read the hold to see it
lift.

## Commands

- `grep ' prof: ' logs/blocked-resolver.log | grep project=cromford | tail -3`
- `grep 'SKIP decline-mark\|decline mark cleared' logs/blocked-resolver.log`
- `grep 'bad_records=' logs/blocked-resolver.log`
- `ls state/blocked-resolver/*/.bad/`
- `BR_OPT_OFF=bh-9029-discovery-index` or `BR_OPT_OFF=bh-9029-decline-mark`
  turns either fragment off.

Tests: `tests/blocked-resolver-discovery.bh-9029-test.sh`,
`tests/blocked-resolver-decline-mark.bh-9029-test.sh`,
`tests/blocked-resolver-bad-record.bh-9029-test.sh`.

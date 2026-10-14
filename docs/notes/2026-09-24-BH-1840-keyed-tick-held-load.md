# A keyed conductor tick loads the held-page cache, so a woken PR's held row waits for the flush

Doc: MERGE-CONDUCTOR

## What changed

Follow-up to BH-1387 (keyed ticks) and BH-1201 (the PAUSED hold), from BH-1831 item 2.

- **`mc_hold_tick_begin --load-only`** (`bin/lib/mc/log.sh`). It reads the held list
  into this tick's cache exactly as the no-arg call does, including the same
  "held pages unreadable this tick (rc=…)" line on an outage. Then it returns. It
  sends no page and no release, and writes no hold-count file. The no-arg call is
  unchanged.
- **A keyed tick calls it** (`bin/merge-conductor.sh`, where the held pages are
  read before the fan-out). An unkeyed tick runs the full flush as before. A keyed
  tick used to skip the call entirely. The call is guarded by
  `declare -f mc_hold_tick_begin | grep -- --load-only`, so a box mid-sync with an
  older `log.sh` keeps today's behavior instead of running a fleet flush inside a
  keyed tick.

## Why

With no cache, `mc_hold_cached` found nothing on a keyed tick. So a woken PR whose
page was held under kill-switch/observe got paged directly by `mc_budget_check`
(and `mc_stuck_check` has the same gate). That page skipped the `MC_FLUSH_MAX` cap
and the "(held since … under mode=…)" text. It also spent `alerted` without
releasing the worker's row, so the next cron flush only retried the release. Now
the keyed tick's pagers see the row as owned by the flush and leave it alone. The
next cron tick pages it once, capped, with the held-since text, and releases it.

Fail-open is unchanged. If the held list is unreadable, the cache stays empty and
the keyed tick pages directly as before. A held row on a stale state or head
doesn't match, so the PR pages for its current state.

## Tests

- `tests/conductor-keyed-held.bh-1840-test.sh` (new): cases A–E through the real
  `bin/merge-conductor.sh`.
- `tests/conductor-wake-keyed.bh-1387-test.sh` case 10: a keyed tick may now GET
  `api/conductor/held`, but it must still send no release POST, write no flush
  line and send no page for a PR it wasn't woken for.

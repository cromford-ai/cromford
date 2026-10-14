# The merge conductor reacts to PR events; the full tick is an hourly sweep (BH-5521)

Doc: MERGE-CONDUCTOR, EVENTS

## Why

On 2026-10-08 each cromford full tick walked about 100 open PRs and took
707-1167 s. A PR that turned READY waited up to a full tick to be enqueued, and
approved PRs sat unqueued for an hour or more. Most of the event path already
existed (BH-1387 keyed runs, BH-3453 owed runs, BH-5463 one full tick at a
time). Four gaps still started fleet-wide full ticks from wakes, and nothing
measured the wait.

## What changed

1. **A pre-queue run wakes its PR.** `bin/lib/mc-prequeue.d/dispatch.sh` runs
   `prequeue-gate.yml` with `--ref main`, so its `workflow_run.completed` carries
   main's sha and named no PR. `wakeOf` (`worker/jobs/src/lib/core.js`) now maps a
   completed `workflow_dispatch` run of `.../prequeue-gate.yml` whose title is
   `prequeue pr=<n> head=<40 hex> main=<40 hex>` to a `pr` row keyed on `<n>`.
   Every other `workflow_run` is still a `checks` row on its head sha.
2. **A wake never starts an unkeyed run** (`bin/wake-loop.sh`, knob
   `WAKE_CONDUCTOR_FULL`, default 0, only with `WAKE_CONDUCTOR_KEYED=1`):
   - A checks sha that `state/merge-conductor/pr-state.tsv` cannot place is
     looked up on GitHub (`GET repos/<repo>/commits/<sha>/pulls`,
     `wck_sha_prs` in `bin/lib/wake-conductor-keys.sh`), at most
     `WAKE_CONDUCTOR_SHA_LOOKUPS` (default 5) per drain. An open PR with that
     head becomes a key. A sha still unplaced is counted (`miss`, `unread`,
     `skipped`) in one line per drain, and the sweep covers it.
   - A drain whose wakes name no PR launches nothing, takes no cooldown and
     owes nothing: `pr/checks: <n> wake(s) named no PR — no conductor run`.
   - The owed pay drops a `*` line, reads the key count before the cooldown
     (an empty debt never burns the window), and launches more than 50 keys
     as 50 keyed runs with the rest put back.
3. **The full tick is hourly.** The `bin/lib/cadence-backstop.sh` default for
   `merge-conductor` is 60 minutes (was 15). The cron line stays `*/30`; with
   the 30 s jitter slack every second fire passes.
4. **The full tick is bounded.** An unkeyed tick sets the BH-4842 worker window
   to `MC_FULL_TICK_BUDGET_S` (default 1500 s) from its start. A PR that does not
   fit is logged `WINDOW_DEFERRED … the next hourly sweep or a wake for this PR
   takes it` and accounted `deferred:window`; its row is not touched. A keyed
   tick and a caller's own `MC_WORKERS_DONE_BY` (the keyed backstop) are
   unchanged. The window is never exported, so no child or detached lane sees
   it. `mc_window_defer` takes its tail from `MC_WINDOW_NEXT` (default: the old
   text). BH-5463's lock still keeps two full ticks of a project from running
   at once.
5. **READY -> enqueued is measured.** `bin/mc-ready-latency.sh` reads the
   `-> QUEUED` transitions in `logs/merge-conductor.log` and prints, per PR,
   `ready_log_s` (from the conductor's own `-> READY` line) and `green_s` (from
   the head's last green gate on GitHub, never `prequeue-verdict`), then one
   `READY_TO_QUEUED` line with p50/p90/max and `target_p90_120s=met|missed`. It is
   a report: it writes nothing and pages nobody.

Not in this change: a label change other than `queued` still wakes nothing
(the wake row stores no label name, and `bin/lib/wake-class-pr-closed.sh` reads
every `labeled` row as `queued`). A Mergify dequeue reaches the PR through
Mergify's check run on the head and its PR comment, both existing wakes.

## Rollback

- `lane.wake-loop.wake_conductor_full=1`: the old unkeyed fall-through, byte
  for byte. `lane.wake-loop.wake_conductor_sha_lookups=0`: no GitHub lookups.
- `lib.cadence-backstop.cadence_backstop_min_merge_conductor=15`: the old sweep.
- `lane.merge-conductor.mc_full_tick_budget_s=0`: no full-tick bound.

## How to measure

```bash
bin/mc-ready-latency.sh --since 2026-10-08 --until <deploy time>    # before
bin/mc-ready-latency.sh --since <deploy time + 24h>                 # after
bin/mc-ready-latency.sh --no-github --repo example-org/cromford  # log only
```

Exit 3 with `INCOMPLETE: no QUEUED transition in the window` means the window
has no enqueue in the current log file. `INCOMPLETE` on the summary line means
a GitHub read failed or `--max` capped rows.

Suites: `tests/conductor-events.bh-5521-test.sh`,
`tests/mc-ready-latency.bh-5521-test.sh`,
`worker/jobs/test/wakeof-prequeue-run.bh-5521.test.js`.

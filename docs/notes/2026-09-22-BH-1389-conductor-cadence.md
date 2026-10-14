# The merge conductor's hub cron line fires every 30 minutes, not every 5

Doc: MERGE-CONDUCTOR

BH-1389. Webhooks wake the conductor through `bin/wake-loop.sh` (C2), and since
BH-1387 a wake runs a keyed tick for just the PRs it drained. The cron line is a
backstop, so it moves from `*/5 * * * *` to `*/30 * * * *`. Nothing else changes.

## What changed

- `cron/lanes/410-merge-conductor.cron`: the schedule field is `*/30`. The rest of
  the line is byte-identical: `hub-lease.sh check &&`, then the
  `bin/lib/cadence-backstop.sh merge-conductor` gate (skip only on rc 3), then the
  lane. The stale "Phase C removes the sweep line above" sentence is gone, because
  BH-1388 already retired the sweep line.
- `catalog/lanes.d/merge-conductor.json`: `cadence` is `*/30 * * * *`.
- `cron/hub.cron` and `catalog/lanes.json` are generated and not committed
  (BH-1247); the hub picks the change up on its next render.

With the default 15-minute backstop row
(`lib.cadence-backstop.cadence_backstop_min_merge_conductor`), every `*/30` tick
passes the gate, so the effective backstop is 30 minutes. A row above 30 skips
every other tick; 0 runs every tick. Conductor minutes `{0,30}` never meet the
blocked-resolver's `4,14,24,34,44,54`.

Knobs counted in ticks (`MC_UNVERIFIABLE_ALERT_TICKS`, `MC_MERGIFY_REASK_TICKS`)
stretch with the cadence. `bin/pipeline-health.sh`'s SWEEPSTALL bar reads
`MC_TICK_SECS`, not the cron, and is not retuned here.

## Precondition probes

Captured 2026-09-28T13:50:19Z on the build box (`pool-cromford-826571a702d728`):

```
$ /root/harness/bin/jobs-client.sh wakes-summary 24
example-org/project-9	117	2026-09-27T23:08:31Z	checks,deploy,pr,push
example-org/project-7	8	2026-09-28T09:28:00Z	checks,deploy,issue,pr,push
example-org/cromford	4451	2026-09-28T13:50:17Z	checks,deploy,issue,pr,push
example-org/project-4	9	2026-09-28T12:12:20Z	checks,pr
example-org/project-1	9	2026-09-28T04:48:18Z	checks,deploy,pr,push
example-org/project-3	7	2026-09-28T04:05:13Z	checks
example-org/project-5	95	2026-09-28T13:43:51Z	checks,deploy,issue,pr
rc=0
$ /root/harness/bin/jobs-client.sh setting-get lane.wake-loop.wake_conductor_keyed
1
rc=0
$ grep -c 'keyed tick' /root/harness/logs/merge-conductor.log
ugrep: warning: /root/harness/logs/merge-conductor.log: No such file or directory
rc=2
```

Probe 3 could not run: that log exists only on the hub. It stands on the
operator's attestation, the operator's RESUME comment of 2026-09-28T13:22Z
(https://github.com/example-org/cromford/issues/1389#issuecomment-5870739183):
"the 24h keyed-tick observation passed (12 keyed ticks in the last 24h, the
setting reads 1 on the hub). Build the */5 → */30 cadence change."

## Rollback

Put the fragment's schedule and the registry's `cadence` back to `*/5 * * * *`,
then re-render (`bin/render-cron.sh --all`, `bin/lanes-build.sh --write`).

## Verify on the hub

`crontab -l | grep merge-conductor.sh` shows `*/30`. Until it does, the change is
merged, not deployed.

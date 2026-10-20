# The hub sheds load (BH-7509)

Doc: OPERATING, MERGE-CONDUCTOR

## Why

On 2026-10-19 the hub (4 vCPU) ran at load average 66-82 all day.
`bin/hub-load-sample.sh` wrote 93 "runnable p90 over hub_load.max_runnable"
alerts, and nothing read them. 38 merge-conductor and 32 fly-pool processes
starved every pool tick: 21 ticks ran past the 1200 s hard limit.

## What changed

1. `bin/hub-load-sample.sh` writes `state/hub-load/verdict` on every run, after
   the p90 step (step 6b). The writer and the reader are in
   `bin/lib/hub-load-shed.sh` (`hls_write`, `hls_over`).
2. Four spawners read the verdict before they fork. While it says over, each
   one starts no new worker and writes one `load-shed p90=<n> max=<n>` line:
   - `bin/mc-keyed-pool.sh drain`: the pool shrinks to a floor of one slot
     (slot 0), so merges never stop while the hub is over. The line is
     `load-shed p90=<n> max=<n> — 1 slot floor, <q> queued`. Slot 0 runs the
     queue one entry at a time. If slot 0 is busy, the drain exits 0 and the
     entries stay queued. A holder of any other slot stops before its next
     pop. Pool off (N=0) runs as N=1. `status` is unchanged.
     Log: `logs/merge-conductor-keyed-pool.log`.
   - `bin/fly-pool.sh <project>`: the SPAWN half exits. REAP and the
     dead-machine sweep still run, so builds that already run finish. The
     queued job files stay. Log: `logs/fly-pool.log`.
   - `bin/fly-pool-tick.sh`: still starts the project ticks (their REAP must
     run) and writes one note line to `logs/fly-pool.log`.
   - `bin/project-lane-run.sh`: a SPAWNING lane exits 0 after its offset
     sleep, before it takes the project lock. The line goes to the lane's cron
     log. Only lanes in `HLS_SPAWN_LANES` (`bin/lib/hub-load-shed.sh`) shed:
     alert-triage, alerts-medic, blocked-resolver, review-autopilot,
     review-rescue, stranded-watch and watchdog-responder. Each one forks a
     build, a fix round or an agent session. Every other lane (for example
     fleet-status-push, dequeue-watch, archie-fm) only reads state and runs
     as before. `HUB_LOAD_SHED_LANES` (space or comma separated) replaces
     the list.
3. New knob `POOL_TICK_MAX_PARALLEL` on lane `fly-pool-tick` (settings row
   `lane.fly-pool-tick.pool_tick_max_parallel`, default 0 = `nproc`).
   `bin/fly-pool-tick.sh` starts at most that many project ticks at once. A
   held `locks/fly-pool-<p>.lock` counts. Free projects go oldest
   `state/fly-pool-tick/<p>.since` first. A project over the cap gets one
   `max-ticks: <n> of <cap> running` line and no stamp. The sequential sweep
   (`POOL_AUTOSCALE=0`) is not capped.
4. The merge-conductor cap is the existing knob `MC_KEYED_MAX_PARALLEL`
   (row `lane.merge-conductor.mc_keyed_max_parallel`, default 4, BH-7139). No
   second knob was added for the same cap.

## The verdict file

One line, TAB-separated, written by tmp file + `mv` under the sampler's lock:

```
v=1	at=<epoch>	runnable=<x|NA>	p90=<x|NA>	max=<n>	state=<over|under|insufficient>	max_age_s=<n>	shed=<1|0>
```

`state=over` means the p90 of the last 6 runnable values is over
`hub_load.max_runnable`. It is a current-value file, not a log: it does not
grow and has no retention rule.

The reader fails open. No file, a malformed line, a line older than
`max_age_s` (or more than 300 s in the future), `shed=0`, or a state that is
not over all mean "do not shed". Only the hub runs the sampler, so every other
box and every Fly machine has no file and never sheds.

## Settings rows

- `hub_load.verdict_max_age_s` (default 1800 = 3 sampler runs). A dead sampler
  stops the shed within this window.
- `hub_load.shed` (default on). `off`, `0` or `false` writes `shed=0`.

## Turn it off

1. Set the settings row `hub_load.shed=off`. The next sampler run (10 min or
   less) writes `shed=0`, and the spawners stop shedding.
2. Or set `flags/lane-off-hub-load-sample`. The verdict goes stale after
   `hub_load.verdict_max_age_s`, then the spawners stop shedding.

The sampler summary line shows the state:
`shed=<over|under|insufficient|off>(verdict=<written|failed>)`.

Test: `tests/hub-load-shed.bh-7509-test.sh`.

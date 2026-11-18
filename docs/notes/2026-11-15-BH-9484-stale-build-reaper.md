# BH-9484: the stale-build reaper lane (observe first)

Slice C0 of #9484, items 4 and 7 of #9406.

## What the lane does

`bin/stale-build-reaper.sh` runs on the hub every 10 minutes
(`cron/lanes/383-stale-build-reaper.cron`, behind `hub-lease.sh check`). It reads
the console feed `GET /api/builds/stale?hours=<floor(MINUTES/60)>` and keeps the
rows in stage `planning` or `executing` whose `updated_at` is at least
`STALE_REAPER_MINUTES` (default 60) old.

A candidate is held (one `HOLD` log line) when any of these 4 evidence sources
has its `(project, key)`:

1. A `queued` or `claimed` build_queue row (`queue_list`).
2. A live machine row (`machines_list "" live`, with `fly_machines_rows` on), or
   a pool file on the hub (flag off).
3. A hub queue file, or a hub build dir changed inside the window.
4. A running job row of any kind with activity inside the window (`job_rows running`).
   This source is stricter than `bin/sweep-stale-builds.sh`.

Liveness matches on `(project, key)`, never on the key alone.

## Fail closed

If the feed or any source does not read, or a read comes back as a full page
(`STALE_REAPER_PAGE`, worker cap 500), the tick makes 0 changes and exits 3.
The first refusal writes one alert line (`--id stale-build-reaper.evidence`) and
the latch `state/stale-build-reaper/evidence-down`. While the latch exists, a
refusal writes a log line only. The first complete read deletes the latch. Every
source is read on every tick, also when the feed is empty, so the latch clears.

## Observe mode (the default)

`STALE_REAPER_ACT` is 0. The lane writes one line per dead build in
`logs/stale-build-reaper.log`:

    OBSERVE would reap <bkey> project=<p> ticket=<KEY> stage=<s> updated_at=<t> age_min=<n>

It makes no POST, no job row change and no alert. `--dry-run` forces observe.

## Act mode

For each dead build, up to `STALE_REAPER_MAX` (default 20) close POSTs per tick:

1. Each running `build` job row of the key that was quiet for the whole window
   is set to `status=failed` (`meta=STALE_REAPED <bkey> age_min=<n>`). That frees
   its file claim. The log word is `claim released job=<id>`, `claim left job=<id>
   to bin/jobs-watchdog.sh` (the PATCH failed) or `claim none`.
2. `POST /api/builds/close {"closed":["<bkey>"]}`. The console sets stage `stale`.
3. Only after `ok:true`: one alert line (`--id stale-build-reaper.<project>.<KEY>`)
   and one `REAPED` log line. A refused POST is one `REFUSED` line. One alert per
   tick names the refused count.

A build past the cap gets one `DEFERRED` line and waits for the next tick.

Each tick ends with one summary line:
`mode=<observe|act> candidates=<n> held=<n> skipped=<n> reaped=<n> deferred=<n> refused=<n>`.

## Switch it on

1. Read `logs/stale-build-reaper.log` on the hub. Check that the `OBSERVE` lines
   name only dead builds.
2. Run `bin/harness-ctl.sh set stale-build-reaper STALE_REAPER_ACT 1`.

Turn it off with `bin/harness-ctl.sh off stale-build-reaper`.

## What the lane does not do yet

- It opens no PR from a dead build's branch (child slice C1, item 5).
- It does not adopt a spec branch in `bin/lib/rb/gates.sh` (child slice C2, item 6).
- It relaunches no build. `bin/blocked-resolver.sh` owns rebuilds.
- It does not change `bin/sweep-stale-builds.sh`, which still runs daily at 04:55.

## Test

`tests/stale-build-reaper.bh-9484-test.sh` runs the real script against a `curl`
stub (0 network calls).

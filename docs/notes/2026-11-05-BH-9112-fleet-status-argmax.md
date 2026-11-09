# BH-9112: the fleet snapshot no longer hits the jq argv limit

Doc: watchdog-spec

## What changed

1. `bin/fleet-status-push.sh` gives every fleet-sized value to jq through a
   file descriptor (`--slurpfile` / `--rawfile` over `<(printf '%s' ...)`),
   never through argv. This covers the full snapshot, its pre-2026-09-14
   fallback, the console beat payload, the prod-red merge and the pause-flag
   merge. Small scalars stay `--arg`.
2. When the full snapshot still falls back, `logs/fleet-status-push.log` gets
   one line per run: `full snapshot fell back: invalid=<fields|none>
   largest=<f>:<bytes>,... env=<bytes> rc=<jq rc>`. ALERTS.log gets one warn
   line per UTC day, id `fleet-status-snap-fallback`, through
   `bin/alert-line.sh`. The day flag is
   `flags/alerted-fleet-status-snap-fallback-<YYYYMMDD>`.
3. The size shed drops the sheddable keys largest first and stops when the
   body is at most `SNAP_CAP` (60000, unchanged). The snapshot carries
   `snapshot_shed: [<dropped keys>]` beside `snapshot_trimmed: "size"`.

## Why

On bh-hub-2 (2026-11-05 21:38Z) every run logged
`/usr/bin/jq: Argument list too long`. One `--argjson` string over
MAX_ARG_STRLEN (128 KiB) makes `execve` fail with E2BIG. The console lost
`hub`, `lanes_down`, `rules`, `ceilings` and the other 2026-09-14 fields. The
old shed also dropped all 20 sheddable fields when one field was too big.

## Check on the hub

1. `grep -c 'Argument list too long' /root/harness/logs/fleet-status-push-cron.log`
   does not grow after the next */10 tick.
2. `grep 'full snapshot fell back' /root/harness/logs/fleet-status-push.log`
   names the cause of any fallback.

Suite: `tests/fleet-status-push-argmax.bh-9112-test.sh`.

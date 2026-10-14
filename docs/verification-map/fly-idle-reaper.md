# Fly idle reaper (BH-6061)

**What it is:** `bin/fly-idle-reaper.sh`, a hub lane at `2-59/5 * * * *`. It
lists every app the org token sees (`flyctl apps list --json`) and each app's
machines (`flyctl machine list -a <app> --json`). Each app gets an idle signal
from `catalog/fly-idle-signals.json`: an exact app name wins, then the longest
prefix that matches from the start.

| source | idle means | busy means |
|---|---|---|
| `pool` (`pool-*`) | now minus the newest `events[].timestamp` / `updated_at` | a `state/fly-pool/*/<mid>.json` tracking file, or a claimed queue row naming the machine |
| `builder` (`builder-*`) | the same clock | `state/fly/<p>.json` naming the machine with `<p>-active.json` beside it, or a claimed queue row |
| `testhost` (`bh-testhost-example-org`) | `bin/testhost-tick.sh idle <mid>` prints the seconds | it prints `0` |
| `exempt` (`bh-ci-runners-example-org`) | never stopped | — |

A `started` machine idle MORE than `fly.idle_stop_after_s` (900; a row
`fly.idle_stop_after_s.<app>` wins) gets `flyctl machine stop`. At most
`fly.idle_max_stops_per_pass` (10) per pass. Each accepted stop POSTs a row to
`/api/fly-idle/stops`. Each pass PUTs the snapshot to `/api/fly-idle/machines`.
Mission Control shows both: Nav FLEET → MACHINES (`/machines`), section
**FLY IDLE**, tables STARTED MACHINES and STOPS IN THE LAST 24 H.

**Why it exists:** testhost-tick could not stop an idle test host for 13 days
(flyctl was not on cron's PATH). On 2026-10-11 the org had 4 idle
performance-16x test hosts.

**How to drive it:**

| what | how |
|---|---|
| the suite (flyctl stub on PATH, jobs-client stub, R1-R19) | `HARNESS_TEST_SANDBOX=1 bash tests/fly-idle-reaper.bh-6061-test.sh` |
| the worker routes | `cd worker/jobs && node --test test/fly-idle.bh-6061.test.js` |
| the panel | `cd console-ui && node --test tests/fly-idle.bh-6061.test.js` |
| on the hub, once | `/root/harness/bin/fly-idle-reaper.sh; grep 'pass apps=' /root/harness/logs/fly-idle-reaper.log \| tail -1` |
| the testhost signal by hand | `/root/harness/bin/testhost-tick.sh idle <machine-id>` (prints seconds, `0`, or `unknown` rc 2) |
| usage | `bin/fly-idle-reaper.sh --help` |

The pass line reads `pass apps= read= failed= partial= started= busy= idle=
over= stopping= stop_failed= unknown= nosignal= exempt= threshold=T(src)
nostop=`. One pass over every app is `failed=0 partial=0`.

**Settings rows** (seeded by `worker/jobs/schema.d/0023-bh-6061-fly-idle.sql`):
`fly.idle_stop_after_s` (900), `fly.idle_nosignal_alert_s` (3600),
`fly.idle_fail_alert_after` (3), `fly.idle_max_stops_per_pass` (10). Off:
`flags/lane-off-fly-idle-reaper` or `bin/harness-ctl.sh off fly-idle-reaper`.

**What usually lies:**

- `stopping` (and a stop row's `status: requested`) is a stop flyctl accepted
  with rc 0. It is not a stop observed. The next pass shows the machine gone
  from `started`, or shows it again.
- The panel's "K over the idle limit" is from the LAST snapshot. Read its
  `as of` time. A failed apps list sends no snapshot, so an old time means the
  lane is not listing.
- `partial` means one or more apps could not be listed. Those apps had no stop
  in that pass.

**What must never regress:**

- **Never destroy.** `machine stop` is the only write to Fly. The suite fails
  on any `destroy` call (R16).
- **Failure is never idle.** An unreadable queue, no `state/fly-pool`, no
  `state/fly`, no timestamp, or a testhost answer that is not a number: the
  machine is `unknown` and not stopped. 3 passes in a row raise
  `fly-idle-fail-<app>` (warn).
- **No signal, no stop.** An app with no registry match is never stopped and
  raises `fly-idle-nosignal-<app>` (warn) after 1 h with a started machine.
- **Settings unreadable, no stops.** The pass reports with `nostop=1`.
- **The threshold is "above".** 900 s idle at a 900 s limit is not stopped.
- **The token never reaches a log, an alert or a row** (R18).

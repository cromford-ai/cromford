# Fly idle reaper (BH-6061, BH-6877)

**What it is:** `bin/fly-idle-reaper.sh`, a hub lane at `2-59/5 * * * *`. It
lists every app the org token sees (`flyctl apps list --json`) and each app's
machines (`flyctl machine list -a <app> --json`). Each app gets an idle signal
from `catalog/fly-idle-signals.json`: an exact app name wins, then the longest
prefix that matches from the start. No match is `metrics` (BH-6877).

| source | idle means | busy means |
|---|---|---|
| `pool` (`pool-*`) | now minus the newer of the last work time (`state/fly-idle-reaper/work/<app>__<mid>`) and the newest `start`/`launch` event; `update`/`exec` events are not work | a `state/fly-pool/*/<mid>.json` tracking file, or a claimed queue row naming the machine |
| `builder` (`builder-*`) | the same clock | `state/fly/<p>.json` naming the machine with `<p>-active.json` beside it, or a claimed queue row |
| `lane-run` (`lane-run`) | `idle_s` of its row in `GET /api/lane-fleet/machines`; the `lane_fleet.warm_floor` (1) lowest-idle machines are kept | `busy` or `in_flight` |
| `testhost` (`bh-testhost-example-org`) | `bin/testhost-tick.sh idle <mid>` prints the seconds | it prints `0` |
| `metrics` (no match; `project-12-openfang-joy`, `project-12-openfang-test`, `project-12-e2e-base`, `project-12-joy-lab`) | Fly Prometheus over `fly.idle_stop_after_s`: busy CPU under `fly.metrics_idle_cpu_pct` (2) and net under `fly.metrics_idle_net_bps` (2048) B/s; idle from the last work time / start event | either rate at or over its line |
| `exempt` (`bh-ci-runners-example-org`, `project-12-*`) | never stopped, never destroyed | — |

Before a pool, builder or lane-run stop, the reaper runs `flyctl machine exec
<mid> 'ps -eo pcpu=,args=' -a <app>` and reads it against
`catalog/fly-work-procs.json`: a `work` process (`run-build.sh`,
`wait-preview.sh`, ...) or an unlisted process at `fly.probe_busy_cpu_pct` (5)
CPU is busy. A failed or unreadable probe is `unknown`. A stopped pool, builder
or lane-run machine stopped MORE than `fly.destroy_after_stopped_s` (604800) is
destroyed (`flyctl machine destroy`, no `--force`; at most
`fly.destroy_max_per_pass` (10); off with `fly.destroy_enabled=0`), and POSTs a
row to `/api/fly-idle/destroys`. A machine with a mounted volume, or whose id is
the `machine_id` of a `state/fly/<p>.json` record (a project's persistent
builder from `bin/fly-provision.sh`), is never destroyed, and a `state/fly`
record that does not parse stops every destroy for the pass. The `lane-run`
image installs `procps` for the probe (`fly/lane-run.Dockerfile`). A lane-run machine whose row is still
`starting` past `fly.no_claim_alert_s` (600) raises `fly-no-claim-<digest12>`,
one per image digest, alert only. `bin/fly-idle-reaper.sh act
probe|stop|destroy|keep <app> <mid> [reason]` is the one-machine path
Quartermaster uses for a `fly-unsettled` finding. `act stop` probes a pool,
builder or lane-run machine itself and refuses unless the probe says idle
(lane-run: and the lane record says not busy, not in flight). It refuses any
stop while a settings row is unreadable.

A `started` machine idle MORE than `fly.idle_stop_after_s` (900; a row
`fly.idle_stop_after_s.<app>` wins) gets `flyctl machine stop`. At most
`fly.idle_max_stops_per_pass` (10) per pass. Each accepted stop POSTs a row to
`/api/fly-idle/stops`. Each pass PUTs the snapshot to `/api/fly-idle/machines`.
Mission Control shows both: Nav FLEET → MACHINES (`/machines`), section
**FLY IDLE**, tables STARTED MACHINES and STOPS IN THE LAST 24 H.

**The panel since BH-6877:** STARTED MACHINES has a LAST WORK column. It shows
the clock time of the reaper's last work witness and how long before the pass
it was (`07:10Z · 16m 40s before the pass`), or `—` when the snapshot row has
no `last_work_at`. The column sorts on the raw time, not on the label. A third
table, DESTROYED (24 H), lists the rows of `GET /api/fly-idle` `destroys`: time,
app (links to Fly), machine id (text: a destroyed machine has no Fly page),
size, stopped for, RESTART $/H (the compute rate a restart would cost; a stopped
machine pays none, so it is not a saving). The heading sums restart $/h over priced rows only and counts
the unpriced ones. When the body has no `destroys` list (a worker before
BH-6877, or `fly_idle_destroys` not applied), the panel prints `destroy list
not available: <why>`, never "no destroys". Each table scrolls in its own
`tablewrap--wide` container, so at 375 px the page body does not scroll
sideways.

**Why it exists:** testhost-tick could not stop an idle test host for 13 days
(flyctl was not on cron's PATH). On 2026-10-11 the org had 4 idle
performance-16x test hosts.

**How to drive it:**

| what | how |
|---|---|
| the suite (flyctl stub on PATH, jobs-client stub, R1-R19) | `HARNESS_TEST_SANDBOX=1 bash tests/fly-idle-reaper.bh-6061-test.sh` |
| lane-run, probe, metrics, destroy, no-claim (U, P, M, D, N) | `HARNESS_TEST_SANDBOX=1 bash tests/fly-idle-usage.bh-6877-test.sh` |
| the Quartermaster finding and the `act` verb | `HARNESS_TEST_SANDBOX=1 bash tests/quartermaster-fly.bh-6877-test.sh` |
| one probe by hand | `/root/harness/bin/fly-idle-reaper.sh act probe <app> <machine-id>` |
| the lane-run source (L1-L14) | `HARNESS_TEST_SANDBOX=1 bash tests/fly-idle-reaper-lane-run.bh-6714-test.sh` |
| the worker routes | `cd worker/jobs && node --test test/fly-idle.bh-6061.test.js` |
| the panel | `cd console-ui && node --test tests/fly-idle.bh-6061.test.js` |
| the destroy route, retention and last-work fields | `cd worker/jobs && node --test test/fly-idle-destroys.bh-6877.test.js` |
| the panel's LAST WORK column and DESTROYED (24 H) table | `cd console-ui && node --test tests/fly-idle.bh-6877.test.js` |
| on the hub, once | `/root/harness/bin/fly-idle-reaper.sh; grep 'pass apps=' /root/harness/logs/fly-idle-reaper.log \| tail -1` |
| the testhost signal by hand | `/root/harness/bin/testhost-tick.sh idle <machine-id>` (prints seconds, `0`, or `unknown` rc 2) |
| usage | `bin/fly-idle-reaper.sh --help` |

The pass line reads `pass apps= read= failed= partial= started= busy= idle=
over= stopping= stop_failed= unknown= nosignal= exempt= threshold=T(src)
nostop= probed= probe_busy= destroying= destroy_failed= noclaim= metrics= floor=`. `floor` counts lane-run machines kept for the warm floor (BH-6714). One pass over every app is `failed=0 partial=0`.

**Settings rows** (seeded by `worker/jobs/schema.d/0023-bh-6061-fly-idle.sql`):
`fly.idle_stop_after_s` (900), `fly.idle_nosignal_alert_s` (3600),
`fly.idle_fail_alert_after` (3), `fly.idle_max_stops_per_pass` (10). BH-6877
(`202610170732-bh-6877-fly-destroys.sql`): `fly.no_claim_alert_s` (600),
`fly.probe_busy_cpu_pct` (5), `fly.metrics_idle_cpu_pct` (2),
`fly.metrics_idle_net_bps` (2048), `fly.destroy_after_stopped_s` (604800),
`fly.destroy_max_per_pass` (10), `fly.destroy_enabled` (1). The
lane-run source also reads `lane_fleet.warm_floor` (1, seeded by
`worker/jobs/schema.d/0022-bh-6047-lane-fleet.sql`; above 100 is 1). Off:
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

- **Destroy only what the rule names.** Only a `stopped` machine of a pool,
  builder or lane-run app, stopped more than `fly.destroy_after_stopped_s`.
  Never a started machine, never an exempt, testhost or metrics app (D2, D3).
  Never a recorded builder or a machine with a volume (D10-D12, Q6b).
- **`act stop` probes in code** (Q7), not only by the prompt.
- **Every probed image has `ps`** (I1).
- **A work process is busy.** A probe that shows `run-build.sh` or
  `wait-preview.sh` stops nothing (P1, P2).
- **Failure is never idle.** An unreadable queue, no `state/fly-pool`, no
  `state/fly`, no timestamp, a testhost answer that is not a number, a
  lane-fleet answer that fails or says `incomplete`, an unreadable
  `lane_fleet.warm_floor`, or a lane-run machine with no `lane_machines` row: the
  machine is `unknown` and not stopped. 3 passes in a row raise
  `fly-idle-fail-<app>` (warn).
- **No signal, no stop.** A metrics app with no org slug (`FLY_ORG` or the
  apps list) is `nosignal`: never stopped, and it raises
  `fly-idle-nosignal-<app>` (warn) after 1 h with a started machine.
- **Settings unreadable, no stops.** The pass reports with `nostop=1`.
- **The threshold is "above".** 900 s idle at a 900 s limit is not stopped.
- **The token never reaches a log, an alert or a row** (R18).

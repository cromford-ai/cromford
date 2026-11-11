# Lane liveness heartbeat (a lane that died says so)

**What it is:** a dead lane and a lane with nothing to do look identical — both
produce no output. `bin/lib/heartbeat.sh` is the writer half: a long-lived lane
declares its rhythm and its expected-by at launch, ticks a file while it works,
and removes that file when it exits cleanly. `bin/heartbeat-reaper.sh` is the
reader half, on the hub cron every 5 minutes: it pages ONCE, through
`bin/lane-alert.sh`, for a lane instance that went silent or died, and marks the
file so it does not page again every five minutes.

**WHAT IT CANNOT SEE — the limit, stated:** for a lane that declares no kind,
this detects a lane that died or wedged **MID-RUN**, because that is what leaves
a file behind. Such a lane that exited cleanly and was never launched again has
no file here and this pass never notices it.

**A `cron` lane is judged by its last COMPLETED tick instead (BH-4717).** A lane
launched with `hb_start ... cron` (today: `merge-conductor`, which the backstop
runs under `timeout 240`) is killed on purpose, so its dead instance file is
dropped with a `heartbeat-reaper.log` line and never paged. Its clean exit
(`hb_done`) writes `state/heartbeat-done/<lane>` (`<epoch>\t<interval>`), and
the reaper pages once when that stamp is older than `interval × HB_STALE_MULT`,
the interval read from the lane's catalog cadence (`hb_cron_interval`). So
"no completed conductor tick for 90 minutes" now pages, whether the ticks are
being killed or not started at all. Retiring a cron lane means deleting its stamp.

**Since BH-1031 the beats are also written THROUGH to the lane's `lanes` row**
(state→DB slice 6, behind `flags/lane-liveness-db`), which is what makes a lane whose
whole BOX went away visible at all — no file survives that, and the ssh probe in
`bin/fleet-heartbeat.sh` that used to stand in for it is deleted. The file contract
below is unchanged and is still the write-ahead — the FILE is written on every single
tick, while the DB copy is rate-limited to one per half rhythm per (lane, pid) and
carries no `interval_s` of its own (the rhythm belongs to the launch). See
[lane-liveness-one-fact.md](lane-liveness-one-fact.md).

## The file contract

`state/heartbeat/<lane>.<pid>.json`, one file **per writer**, not per lane:

```json
{"lane":"merge-conductor","pid":12345,"box":"hub","started_at":1758000000,
 "last_tick":1758000300,"interval":300,"deadline":1758001800,"note":"tick project-3",
 "blocks":"PR merges fleet-wide","restart":"","stale":false,"stale_at":0,"kind":"cron"}
```

`kind` is present only when the launch declared one (`hb_start`'s 6th argument).
A lane that declares none writes exactly the bytes it wrote before BH-4717.

Per writer because `merge-conductor` (\*/5) and `blocked-resolver` (\*/10, fix
rounds up to 5400s) OVERLAP as their normal state. With one `<lane>.json` the
healthy successor's launch refreshed the wedged instance's file back to "fresh",
and whichever of the two finished first deleted it — the wedge was masked twice
over. Keyed on `(lane, pid)` a wedged instance keeps its own file, its own
`started_at` and its own deadline; `hb_done` removes only the caller's. The
reaper globs `*.json` and reads `lane` out of the body, so two instances of one
lane are two findings about the same lane.

| function | what it does |
|---|---|
| `hb_start <lane> [interval_s=300] [expect_s=3600] [blocks] [restart] [kind]` | the launch declaration. `expect_s` of `0` writes `deadline: 0` — **no expected-by**, for a loop that is supposed to run for ever. `kind` `cron` writes `"kind":"cron"` |
| `hb_tick [lane] [note]` | the one line a loop adopts. Moves `last_tick`/`note` and **nothing else** — never the launch's numbers, and never `stale`/`stale_at`. With no file yet it writes one at the defaults, which is what makes one-line adoption true |
| `hb_done [lane]` | a clean exit takes its own file with it. On a `kind:cron` file it first writes the completion stamp `state/heartbeat-done/<lane>` (`<epoch>\t<interval>`, tmp+mv, best effort) |
| `hb_done_dir` | `state/heartbeat-done`, beside `state/heartbeat` like `-db`. Holds `<lane>` (the stamp) and `<lane>.paged` (the `last_done` the reaper paged) |
| `hb_cron_interval <lane> [fallback]` | seconds between ticks from `catalog/lanes.d/<lane>.json` `.cadence`, only when hour/day fields are all `*`: `*` 60, `*/N` N×60, a minute list its largest gap (wrap included), one minute 3600. Anything else, or no catalog/jq, is the fallback. Prints max(parsed, fallback) |
| `hb_mark_stale <file> <now> [true\|false]` | the reaper's own writer: `true` marks (with `stale_at`), `false` clears both. rc 1 if it could not be written |
| `hb_state <file> <now> [boot_at] [nomark]` | one word: `marked` \| `fresh` \| `silent` \| `overdue` \| `dead` \| `unparseable`. `nomark` skips the `marked` short-circuit and answers with the word underneath, which is how the reaper asks whether a file it already paged has recovered |
| `hb_file <lane> [pid]`, `hb_dir` | the paths |

**`stale` / `stale_at` belong to the READER.** A tick never clears them. If the
writer cleared them, an alive-but-overdue lane would unmark itself on every tick
and the reaper would re-find it, re-mark it and re-fire the same id every five
minutes for as long as the lane ran — invisible in `ALERTS.log` (`lane-alert`
suppresses an open id) and perfectly visible as a `still firing` row every pass
in `logs/alerts-state.log`, plus a reminder page every `ALERT_REMINDER_S`.

Seams for tests: `HB_NOW`, `HB_DIR`, `HB_PID`, `HB_STALE_MULT`, `HB_SILENT_FLOOR_S`, `nomark`, and
`HB_BOOT_AT` on the reaper.

**The lib never fails its caller.** Every write is best effort and every
function returns 0 — a lane must never die of its own heartbeat. Writes need no
`jq` (printf + tmp + `mv`), so the `*/5` reader never sees a torn file. Reads
need `jq`; on a box without it every file reads `unparseable`, which pages once
rather than going quiet.

## The reaper's states and ids

| state | meaning | what the pass does |
|---|---|---|
| `fresh` | ticking inside its rhythm, inside its expected-by | nothing |
| `marked` | already paged | nothing is ever *fired* again, whatever the lane does. Two exceptions, both quiet: it is back inside its rhythm AND it ticked after `stale_at` → clear the mark and send exactly one `--resolve`; past `HB_STALE_GC_S` → GC |
| `silent` | alive, `now - last_tick > max(interval × HB_STALE_MULT, HB_SILENT_FLOOR_S)` | mark, then send |
| `overdue` | alive and ticking, past a non-zero `deadline` | mark, then send |
| `dead` | `kill -0` fails, or `last_tick` predates the boot (`/proc/uptime`) | mark, then send, then restart if declared |
| `dead` + `kind:cron` | a cron tick that was killed (no `hb_done`) | remove the file and its `-db` stamp, log `<lane>: cron tick pid <p> ended without hb_done — not a page`. No page |
| `cron-stale` | the stamp in `state/heartbeat-done/<lane>` is older than `hb_cron_interval × HB_STALE_MULT`, no instance of the lane is `fresh`, and `.paged` is not already that stamp | write `.paged`, then send once, id `hb-cron-<lane>-<last_done>`. A newer stamp sends `--resolve` for it and removes `.paged`. Skipped with a log line under `flags/all-off`, `flags/lane-off-<lane>`, or a `scope:hub` lane on a box `bin/hub-lease.sh check` says is not the holder. A future stamp reads as age 0; an unreadable one is logged and skipped |
| `unparseable` | bad JSON, missing field, or no `jq` | send (never marked, never rewritten — it is evidence) |

The floor (BH-4717) is why a wake-loop at interval 15 is not called silent 50s
after a tick: under the default `HB_SILENT_FLOOR_S=120` the threshold is
`max(45, 120) = 120`. `0` turns the floor off and leaves `interval × HB_STALE_MULT`
as it was; a non-numeric value falls back to 120. The floor gates `silent` only,
`overdue` is unchanged. Every age the reaper prints goes through `hb_age_text`:
`<n>s` under a minute (`silent for 50s`), whole minutes from one up
(`silent for 2m`), so `silent for 0m` can no longer be printed.

Ids: `hb-<lane>` per lane (BH-9114: two dead pids of one lane in one pass are
one finding, and a lane dead again under a new pid while `hb-<lane>` is open is
a suppressed repeat), `hb-<file>-unreadable` for a corrupt file,
`hb-mass-<sha of the sorted ids>` for a collapsed wave.

**A SPENT RUN IS NOT A DEAD LANE (BH-9114).** A dead, non-cron instance is
removed with a `<lane>: pid <pid> ended; <evidence> — not a page` log line when
a later run of the same lane (the `.lane` field, `started_at` strictly greater)
exists, or the lane's completion stamp `state/heartbeat-done/<lane>` is newer
than its start. After a dead page the reaper writes `<lane>.hbpaged`
(`<epoch>\t<lane>`) beside the heartbeat files; a fresh run of the lane, or a
completion stamp newer than the page, resolves `hb-<lane>`, and a marker older
than `HB_STALE_GC_S` is removed with no resolve.
`bin/lane-alert.sh --id` and `state/alerts/<id>.json` own the dedupe; this lane
does not re-invent it.

**MARK, THEN SEND.** Dying between the two loses one alert; dying between send
and mark pages every five minutes for ever, which is the complaint this lane
answers. A mark that fails is logged and **the alert still goes out** (fail-open).

**RECOVERY ENDS THE CONDITION, ONCE.** An alert is a condition with a lifecycle
(`bin/lane-alert.sh`: it fires once, it persists, it ends), so a lane that starts
ticking again gets one `--resolve` on the id that fired, not silence and not a
second page. "Recovered" is deliberately narrow: `nomark` state `fresh` **and**
`last_tick > stale_at`. A lane that is alive but past its expected-by never
reaches it — it stays marked and silent for the rest of its run, which is the
point. On an unknown or already-closed id `lane-alert --resolve` is silent by
contract, so nothing is retracted that nobody was told about.

`HB_MASS_STALE_N` findings in one pass collapse to ONE line — a hub reboot kills
every lane at once and N lines is the same silence in a different costume. The
reboot clause is written only when `boot_at > min(started_at)` says so. **The
collapse also opens each member id** through `bin/lib/alert-state.sh`: the lanes
inside it are marked and drop out of the next pass, but an `unparseable` file is
never marked (it is evidence), so it would come back alone, below the threshold,
and page under its own id — a per-lane line five minutes after the collapse that
was supposed to be the whole story. Registered, that second sighting is a
`suppress`. Without the lib the legacy `lane-alert` path registers nothing and
pages every time, which is the fail-open that path already documents.

## The knobs

All optional, hub only, documented in `env-templates/global.env.example`. Code
defaults are the same five values; nothing here is a required env var.

`HB_STALE_MULT=3` · `HB_SILENT_FLOOR_S=120` (0 = off) · `HB_MASS_STALE_N=3` · `HB_RESTART_PER_HOUR=3` ·
`HB_STALE_GC_S=86400`

**The reaper reads them out of `env/global.env` itself** (`bin/lib/env-path.sh`
resolves the directory), because the cron line is the script and nothing else —
a knob only the environment could carry would be a knob nobody on this box can
turn. Only `HB_<NAME>=<digits>` lines are taken, anything else in the file is
ignored (a `HB_STALE_MULT=abc` leaves the code default of 3 standing), and a
value already in the environment wins over the file. `HB_SILENT_FLOOR_S` and
`HB_STALE_MULT` are also settable on the `heartbeat-reaper` lane
(`catalog/lanes.d/heartbeat-reaper.json`): `lane_env_apply` puts the settings row
in the environment before the file is read, so the row wins and `global.env` is
the fallback. It is a `sed` extract and
**not** `set -a; . global.env` on purpose: the restart branch `nohup`s a lane,
and a sourced `global.env` would hand that child every secret in the file.

## How an operator reaches it

`cron/hub.cron`: `*/5 * * * * /root/harness/bin/heartbeat-reaper.sh`. There is
no UI. The screens are `logs/ALERTS.log` (one line per dead lane, one per reboot
wave, one `RESOLVED:` per recovery), the `fleet_alert` beat the same line rides,
`logs/alerts-state.log` (the suppressed repeats — this file staying empty for a
ticking overdue lane is the point of the mark), `state/alerts/hb-*.json` (the
open conditions, including every member of a collapsed wave),
`logs/heartbeat-reaper.log` (one line per finding per pass, plus `recovered` and
`gc:` rows), `state/heartbeat/` itself (a `merge-conductor.<pid>.json` is present
only while a tick is running) and `state/heartbeat/restarts.log` (TSV
`epoch\tlane\tcmd`).

**Neighbours, and why they are not this.** `lane_tick` / `lanes_list` in
`bin/jobs-client.sh` records that a CRON FIRED for a `(project, box)` — DB-backed,
paged by its own reader, and a different question from "is this long-running
process still alive mid-run". `bin/jobs-watchdog.sh` watches claimed-job beats in
the jobs DB. Two other stores, two other questions; the ids here all start `hb-`,
so nothing collides. The `hb.<lane>` rows BH-1031 adds are this same lane's own
beats in the one place a dead box cannot hide them — not a fourth answer.

## Adopting it in a lane

Three lines, and all three are optional by construction — a box whose
`bin/harness-sync.sh` has not landed the lib yet runs the lane byte for byte as
it did before:

```bash
# shellcheck source=bin/lib/heartbeat.sh
[ -r "$H/bin/lib/heartbeat.sh" ] && . "$H/bin/lib/heartbeat.sh"
command -v hb_tick >/dev/null 2>&1 || { hb_start(){ :; }; hb_tick(){ :; }; hb_done(){ :; }; }
hb_start my-lane 300 1800 "what a silence here blocks"   # at launch
hb_tick  my-lane "what it is doing"                      # in the loop
hb_done  my-lane                                         # before a clean exit
```

Adopted in this repo by `bin/merge-conductor.sh` (300 / 1800),
`bin/blocked-resolver.sh` (`BR_FIX_LANE_TIMEOUT/3` / `BR_FIX_LANE_TIMEOUT` — the
rhythm has to be a third of the deadline, because a fix round blocks
synchronously inside the per-key subshell and cannot tick) and
`bin/wake-loop.sh` (`WAKE_LOOP_INTERVAL_S` / `CYCLES × INTERVAL + 600`, and
`deadline: 0` when `WAKE_LOOP_CYCLES=0`).

**NOT adopted here:** the orchestrator's gate loops in `/root/orchestrator`,
which is outside this repo and keeps its own copies of these scripts — the
recipe above is the whole change there. `bin/run-triage.sh` is a short per-tick
process whose liveness is already the `lanes` row's cron half, so it does not adopt
either.

## How to drive it

| what | how |
|---|---|
| the whole lane — lib contract, every reaper state, the three real lanes, the cron line | `HARNESS_TEST_SANDBOX=1 bash tests/heartbeat-reaper.bh-638-test.sh` |
| cron lanes — killed ticks, the completion stamp, the staleness page, the cadence parse, the real conductor | `HARNESS_TEST_SANDBOX=1 bash tests/heartbeat-cron-lanes.bh-4717-test.sh` |
| one pass by hand on the hub | `HB_NOW=$(date +%s) /root/harness/bin/heartbeat-reaper.sh; echo rc=$?` then read `logs/heartbeat-reaper.log` |
| what the hub thinks is running right now | `ls /root/harness/state/heartbeat/` |

## What must never regress

- **No lock, no signal, no wait.** The reaper takes no lock (locks in this
  harness are dedupe, never a queue) and sends no signal at all — `kill -0` is a
  liveness probe, and there is no `pkill -f` anywhere near a lane name. A live
  process whose argv reads like a lane survives every pass.
- **A detector that goes quiet is the bug.** No `bin/lib/heartbeat.sh` on the
  box: one ALERTS line saying **NO lane liveness check ran** and rc 2. No
  `bin/lane-alert.sh`: the line is written straight into `ALERTS.log` and the
  reaper's log says why. A corrupt file pages; it is never skipped.
- **The negatives.** A fresh lane, a lane at exactly
  `max(interval × HB_STALE_MULT, HB_SILENT_FLOOR_S)` (the boundary is `>`), a live
  lane under the 120s floor, an `interval: 0` lane between ticks, a `last_tick` from
  the future (clock skew), an already-`marked` file, a lane that exited cleanly,
  the surviving instance of an overlapping pair, a `deadline: 0` loop 24h into
  its run, an alive-overdue lane ticking every pass for hours, the unreadable
  member of a collapsed wave on the pass after, and a knob typo in `global.env`
  must all stay silent.
- **Restart is opt-in, split, capped and ledgered.** Only a `dead` lane whose
  own file declares `restart`; the command is split on whitespace and never
  handed to a shell; it must be an absolute, executable path; the ledger row is
  written BEFORE the launch (a broken command must not be retried all hour); the
  cap is `HB_RESTART_PER_HOUR`. The alert's clause is written FROM the outcome —
  "refused", "cap reached", never "relaunched" on a launch that did not happen.
- **A dead lane leaves its file.** That file, marked stale, IS the signal; only
  a clean exit or a relaunch removes one.
- **No secret rides a relaunch.** The reaper takes only numeric `HB_*` lines out
  of `global.env`; nothing else enters its environment, its logs, or the
  environment of a lane it `nohup`s.
- **Build-proof only.** This lane has never been driven on the live hub by the
  build that shipped it: every claim above comes from the fixture suite running
  the real scripts.

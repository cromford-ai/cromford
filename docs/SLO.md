# Fleet SLOs

> `bin/fleet-slo.sh` (hub, cron `*/10`) · thresholds in `flags/slo.conf` ·
> state in `state/slo/` · output `state/slo/status.json` + `logs/fleet-slo.log`
>
> **Scheduled since K1 (2026-09-24).** Until then no cron fragment ran it: the
> "cron `*/10`" above was documentation only. `cron/lanes/716-fleet-slo.cron`
> is the line, `catalog/lanes.d/fleet-slo.json` the registry row, and the lane
> now also honours `flags/lane-off-fleet-slo` / `bin/harness-ctl.sh off
> fleet-slo` beside `flags/fleet-slo-off`. **It runs `--dry-run`**: every
> BREACH and summary line lands in `logs/fleet-slo.log`, nothing pages, no
> incident opens, no `status.json`. The detector has no hysteresis and its
> thresholds were never checked against the live fleet; going live is removing
> `--dry-run` from the fragment once a day of that log says the numbers are real.

## The incident this exists for

On **2026-09-15 at 12:27Z** a lane hot-patched `bin/queue-line-drop.sh` on the hub
and all 8 boxes without committing it. `bin/context-gate.sh` compares live `bin/`
against the box's own checkout before every build, so from that moment it refused
**every box-side build, fleet-wide, for 77 minutes**.

The fleet had stopped. What that produced was four unrelated
`BUILD REFUSED, harness bin drift` lines in four project logs. No incident, no page,
and no way to see it except by reading four files and joining them by hand.

Every layer was working. `pipeline-health.sh` watches queues, machines and spend.
The `lanes` row watches boxes (BH-1031 deleted `fleet-heartbeat.sh`). `jobs-watchdog.sh` watches ledger rows. None of
them watched a **rate**, and a failure that hits everything at once is a rate long
before it is a log line anyone reads.

Two things came out of it, and they are deliberately separate:

1. **The cause got cheaper** — bin drift now self-heals from the checkout instead of
   refusing (see [the gate](#the-other-half-bin-self-heal) below).
2. **The class got visible** — this page.

Fixing the cause does not make the class go away. The next thing that refuses every
build will not be bin drift.

---

## The five SLOs

Each is computed from evidence the hub already holds. Each has a threshold in
`flags/slo.conf`. Each fires **one** incident alert on the way in and **one**
resolve on the way out.

| SLO | measures | evidence | default |
|---|---|---|---|
| `build_refusal` | refusals / build attempts | `logs/ALERTS.log`, `logs/fleet-alerts.log`; attempts from `builds/*/context.json` + `state/remote-results/` | ≥ **0.25** over 60m, floor 4 attempts |
| `lane_death` | settled lanes with no usable RESULT / lanes started | `builds/*/RESULT`, `state/remote-results/*.json` | ≥ **0.30** over 360m, floor 4 lanes |
| `stale_running` | ledger rows still `running` past a TTL | `GET /api/jobs?status=running` | ≥ **3** rows past 180m |
| `box_silent` | boxes whose every lane has gone silent | `lanes` rows (`lanes_list`) | ≥ **1** box, every lane stale and quiet 60m |
| `main_red` | default branches red | `flags/main-red-<slug>` | ≥ **1** |

### `build_refusal`

A refusal is a build **turned away before it started** — the gate said no. That is a
different failure from a build that ran and failed, and it is the one that goes
fleet-wide, because every project on a box shares the box's rules and bin.

Refusals are matched with `SLO_REFUSAL_RE`, whose default is anchored on the
project tag `context-gate.sh` writes (`[project-3] BUILD REFUSED`) rather than on the
bare words. That matters: the first version matched any line containing
"BUILD REFUSED", and on the hub it counted a **retraction line that quoted the
refusal shape** as eight more outages.

The denominator is `max(launches, refusals)`. During a fleet-wide refusal storm the
refusal lines reach the hub long before the build dirs do, and dividing by a launch
count that never arrived would read `0.00` through the whole outage. The
`SLO_REFUSAL_MIN_LAUNCHES` floor is what stops that from firing on one stray line.

### `lane_death`

A lane is **started** once its build dir has a `context.json`, and **settled** once
that is `SLO_LANE_SETTLE_MIN` old — anything younger is working, not dead. Dead
means one of:

* **no `RESULT` at all** — what a max-turns kill or a reaped machine leaves behind;
* a `RESULT` whose first line is not a canonical prefix (`bin/result-prefix-ok.sh`;
  flyctl panics land here);
* an explicitly failed outcome (`SLO_LANE_DEATH_RE`).

`BUILD_REFUSED` is **not** counted here — `build_refusal` owns it, and paging twice
for one cause is how an operator learns to skim. Neither are `PLAN_BLOCKED`,
`REVIEW_BLOCKED` or `DECOMPOSED`: those are lanes that finished with an answer.

This SLO has its **own, longer window** (`SLO_LANE_WINDOW_MIN`, default 360m). It has
to: a lane is only judged once it has settled, so a 60m window over a 90m settle time
could never contain one judgeable lane, and the SLO would have read `0.00` forever.

Remote lanes the hub holds no copy of (BH-8364): one read of the newest `rr-relay` ledger rows per run (`SLO_RELAY_ROWS_LIMIT`, default 200, 0 = no read). A row with no `builds/<build-id>` and no hub json adds a lane here (and a launch to `build_refusal` when it is inside that window), and a death when its result matches `SLO_LANE_DEATH_RE`.

### `stale_running`

A row that says `running` long after any real build could still be running is a lane
the ledger lost. Nothing closes it, nothing is watching it, and it keeps a build slot
while hiding a dead lane behind a green status.

### `box_silent`

Since BH-1031 (state→DB slice 6) this is read from the `lanes` rows the boxes write
for themselves: a box is "lost sight of" when EVERY lane `fleet.conf` routes to it is
stale on the worker's own threshold. One dead lane is a lane problem, and
`jobs-watchdog.sh` already names it; all of them is a box.

A box counts only when EVERY one of its lanes is stale **and** the quietest of them
has been quiet longer than `SLO_BOX_SILENT_MIN` (60m) — a floor that keeps this SLO
strictly behind the per-lane detector, so the two never page for one event.

`bin/fleet-heartbeat.sh` used to answer this by ssh'ing each box every 15 minutes to
stat a log file, and it is deleted — that probe answered "can the hub REACH it", which
is not the same question (a box off the tailnet still runs its own cron). Nothing
reads `state/fleet-heartbeat` any more: a file nothing rewrites would report a
permanently silent fleet, which is the worst shape a detector can take because it
looks like evidence. No answer from the ledger reports `unknown` and fires nothing.

*Historic:* `fleet-heartbeat.sh` rewrote `state/fleet-heartbeat/alerts-<box>` on every
tick where it could read a box, and wrote `unreachable-<box>` when it could not. A
**stale** `alerts-` file therefore meant the heartbeat stopped running for that box —
the one failure the heartbeat could not report about itself.

Counted **only for boxes `fleet.conf` still names.** Retired boxes keep their rows
exactly as they kept their files: measured on the hub on 2026-09-15,
`box-project-3-1` (replaced by `project-3-2` on 08-10) and
`box-project-10-1` (retired 08-24) were both still present. Unfiltered,
this SLO would have paged about two machines that do not exist, every ten minutes,
until someone muted it. Same rule as `bin/rules-drift-check.sh`: a row `fleet.conf` does not
carry is not a box.

### `main_red`

`flags/main-red-<slug>` markers belong to whichever lane watches default branches.
`fleet-slo.sh` **reads** them and never creates or clears one.

---

## Incidents: one in, one out

State lives in `state/slo/<name>.open`, which carries the incident id it was opened
with:

```json
{"incident":"slo-build_refusal-20260915T1227Z","slo":"build_refusal",
 "opened_at":"2026-09-15T12:27:00Z","opened_epoch":1789475220,
 "value":"1.00","threshold":"0.25","detail":"…"}
```

* **Breach** → `lane-alert.sh --critical` once, marker written, id minted.
* **Still breached** → nothing. A rate that stays over for an hour is one incident,
  not six pages. The tick is recorded in `logs/fleet-slo.log`.
* **Cleared** → `lane-alert.sh` once, naming the **same** id, with how long it was
  open. Marker removed.

`--critical` is deliberate: when the orchestrator monitor is off, `lane-alert.sh`
DMs the operator directly, and an SLO breach that only the off monitor would have read is
the 77 minutes again.

## Failing quiet

**Every SLO reports `unknown` and fires nothing when its evidence is missing** — an
unreadable ledger, an absent `fleet.conf`. A detector that pages when it breaks is a
detector that gets muted. What makes that safe is that each SLO's evidence is written
by something that alerts on its own absence: the `lanes` rows for boxes,
`jobs-watchdog.sh` for rows, `pipeline-health.sh` for queues.

`unknown` is never `0`. It appears as `unknown` in `status.json` too.

## Read-only about the world

It reads logs, build dirs, `state/`, `flags/` and the ledger over `GET`. It writes only
`state/slo/`, `logs/fleet-slo.log`, and alerts. It never pauses a project, closes a
row, or touches a `main-red` marker. A detector that could act on its own findings
would be a second, unreviewed control path.

## `status.json`

```json
{ "generated_at": "…", "host": "hub", "window_min": 60, "open_incidents": 1,
  "slos": [ { "slo": "build_refusal", "value": "1.00", "threshold": "0.25",
              "breached": true, "incident": "slo-build_refusal-…", "detail": "…" } ] }
```

Flat on purpose: Mission Control reads the measured value, the threshold it was
measured against and the open incident id — never prose it would have to parse.

## Running it

```bash
bin/fleet-slo.sh              # cron */10 — measures, alerts, writes status.json
bin/fleet-slo.sh --dry-run    # measures and prints; no alerts, no markers, no status.json
```

Exit `0` = every SLO inside its threshold, `1` = at least one incident open.

Kill switch: `flags/fleet-slo-off`. Thresholds: `flags/slo.conf` — the repo copy is the
documented default set, and every key is optional because `fleet-slo.sh` carries the
same value as its fallback. `harness-sync` deploys `bin/ prompts/ catalog/ fleet.conf`,
**not** `flags/`, so changing a threshold on a box is a deliberate act. An SLO quietly
widened is an SLO quietly switched off.

---

## The other half: bin self-heal

`bin/context-gate.sh` used to refuse on bin drift because "rsyncing over a script while
it is executing" ate a build in July 2026. That reasoning was right about **in-place
writes** and wrong about the cost of refusing.

Drifted top-level `bin/` files are now restored from the checkout with **temp file +
`mv`** — a rename swaps the directory entry while any already-running copy keeps its
open inode — logged as `BIN SELF-HEAL <file> <old sha8> -> <new sha8>`, announced with
one `lane-alert.sh` line, and the build **proceeds**.

Two bounds, because the checkout is what we copy *from*:

* it must be **clean and at `origin/main`** (`git status --porcelain` empty, `HEAD ==
  origin/main`). A checkout someone is working in would push a half-finished edit onto
  every lane on the box. When it is not, the old refusal stands and names which of the
  two conditions failed.
* `flags/bin-self-heal-off` turns it back into a refusal.

The displaced live copies are kept under `state/bin-selfheal/<stamp>/`. What gets
overwritten is, by definition, code no commit records — on 2026-09-15 it was somebody's
hot patch — and a heal that destroys it silently is a worse trade than the refusal it
replaced. A hot patch worth keeping still has to be committed and pushed, because the
next `harness-sync` deploy overwrites it exactly the same way.

The scope is deliberately identical to what `bin/context-signature.sh` measures
(`maxdepth 1 -type f`, only files the checkout owns): healing wider than the signature
measures would rewrite files nothing complained about and could never clear the flag it
was called for.

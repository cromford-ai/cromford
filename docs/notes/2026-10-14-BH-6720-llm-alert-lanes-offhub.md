# The LLM alert lanes have input manifests (BH-6720, BH-6047.7)

Doc: PROJECT-LANES

## What changed

- Three lanes have one input manifest pair each, in the format of
  `docs/notes/2026-10-14-BH-6719-lane-run-inputs-manifests.md`:
  `catalog/lane-run-inputs.d/{alert-triage,alerts-medic,watchdog-responder}.{ro,rw}`.
- No lane script, lib, cron line, settings row or schema fragment changed.
  With no `lane_placement.<lane>` row, each lane stays on the hub, and the
  publisher puts no snapshot for it.
- `tests/llm-alert-lanes-offhub.bh-6720-test.sh` proves four things:
  - A1: a demo snapshot holds demo's files and ALERTS lines only.
  - A2: a real alert-triage run on a machine root fed from that snapshot
    sees demo's alert, and writes back inside `.rw` only.
  - A3: no model key of any project is in a snapshot or in the machine env.
  - A4: a write-back outside `.rw` is rejected whole.

## ALERTS.log rides as the project's lines

No project run of these three lanes parses `logs/ALERTS.log` as input. They
only append to it. Each lane reads its alerts from another source:

| lane | input | where |
|---|---|---|
| alert-triage | `state/alert-triage/$p/inbox.tsv` | bin/lib/triage-inbox.sh:47, bin/alert-triage.sh:211-231 |
| alerts-medic | the alerts API and table | bin/alerts-medic.sh:236-262 |
| watchdog-responder | `state/stale-owed.json` | bin/watchdog-responder.sh:217-225 |

The tooled triage session can open ALERTS.log from the orientation map
(bin/triage-map.sh:176). Each `.ro` therefore carries it as an `@lines` entry
with this ERE:

    (^|[^A-Za-z0-9_.-])$p([^A-Za-z0-9_.-]|$)

An ALERTS line has no project column (bin/alert-line.sh:14). The filter keeps
a line that names the project as a whole token. Examples that stay: `demo:`,
`[demo]`, `project demo;`, a line that ends in `demo`. Examples that go:
`demo10`, `demo-old`, `xdemo`, `other-demo-ish`, a line that names only
`other`, and a line that names no project. A line that names two projects
goes to both snapshots. `bin/project-of.sh` uses a different rule (the
earliest mention). An `@lines` ERE cannot run it.

## Inventory, per lane

R = read, W = write. Every R entry is in the `.ro`, and every W entry is in
the `.rw`. A `.ro` snapshot also holds the `.rw` entries.

### alert-triage (`bin/alert-triage.sh $p`)

| entry | R/W | where |
|---|---|---|
| `state/alert-triage/$p/**`: inbox.tsv, work.tsv, deferred.tsv | R W | alert-triage.sh:213, 231; triage-inbox.sh:47 |
| `state/alert-triage/$p/**`: alert-families.json, alert-triage-cliff.json, alert-fix-prs.json | R W | alert-triage.sh:644, 647, 670 |
| `logs/ALERTS.log` (`@lines`) | R | triage-map.sh:176 (pointer only) |
| `fleet.conf` | R | alert-triage.sh:1420; fleet-conf.sh:64 |
| `flags/*` | R | alert-triage.sh:42, 143; lane-gate.sh:238; alert-state.sh:57 |

### alerts-medic (`bin/alerts-medic.sh $p`)

| entry | R/W | where |
|---|---|---|
| `state/alerts-medic/$p/**`: medic-seen.txt, medic-families.json, medic-parked.json | R W | alerts-medic.sh:132, 346-347, 813-814, 830, 846 |
| `logs/medic-run.$p.txt` | W | alerts-medic.sh:725-726, 791 |
| `logs/ALERTS.log` (`@lines`) | R | none (append only) |
| `fleet.conf` | R | llm-lane-project.sh `llp_arm`; fleet-conf.sh:64 |
| `flags/*` | R | lane-gate.sh:238; lane-switch.sh:150, 206; alert-state.sh:57, 174 |

### watchdog-responder (`bin/watchdog-responder.sh $p`)

| entry | R/W | where |
|---|---|---|
| `state/watchdog-responder/$p/**`: stale-history.json, stale-owed.json, .wedgekeys | R W | watchdog-responder.sh:133, 219-225, 253-267, 906-907 |
| `logs/responder-decide.$p.txt`, `logs/responder-run.$p.txt` | W | watchdog-responder.sh:784, 790-810, 816-851 |
| `state/stale-owed.json` | R | watchdog-responder.sh:217-220 |
| `state/build-queue/$p/*.json` | R | watchdog-responder.sh:274-283 |
| `state/fly-pool/$p/*.json` | R | watchdog-responder.sh:284 |
| `logs/ALERTS.log` (`@lines`) | R | none (append only) |
| `fleet.conf` | R | llm-lane-project.sh `llp_arm`; watchdog-responder.sh:322, 385 |
| `flags/*` | R | watchdog-responder.sh:78, 144; lane-gate.sh:238; alert-state.sh:57 |

`state/stale-owed.json` is one JSON object keyed by project. No manifest
directive filters JSON, so it rides whole: demo's snapshot holds every
project's owed-ticket entry. It holds no credential. The run keeps only its own
entry (line 220).

Three changes from the plan's provisional list:

- alert-triage STEP 0 reads and writes `state/triage-prstate.json`
  (bin/triage-spool-retire.sh:140). It does not read
  `state/merge-conductor/pr-state.tsv`, so that file is not in the `.ro`.
- The fleet-wide seeds are not carried. These are `state/medic-seen.txt`,
  `state/medic-families.json` and `state/medic-parked.json`
  (alerts-medic.sh:133-139), and alert-triage's `state/alert-families.json`,
  `state/alert-triage-cliff.json` and `state/alert-fix-prs.json`. A run reads
  a seed only when the project's own copy is absent. The project's copy
  rides in `.rw`, and the hub has written it since BH-5942. A seed holds
  every project's alert ids.
- The responder's per-project output files are in its `.rw`.

## Where a lane machine reads the model key

The read point is the same as on the hub:

1. `bin/lib/llm-lane-project.sh` (`llp_arm`) exports
   `ACCOUNT_PROJECT_FOR_LANE=<word>=<project>` for one project's run.
2. `account_for_project <word>` (bin/lib/project-account.sh) reads the label
   from the settings row `account.<project>`.
3. `project_account_exports` reads the token from
   `<harness_env_dir>/accounts.d/<label>.env`.
4. When the pin exists and that file does not, `bin/agent-call.sh:2420-2431`
   refuses the claude call with rc 76. It never falls back to a shared
   account.

`fly/lane-run-entrypoint.sh` writes only `global.env` (JOBS_URL,
HARNESS_SECRET) and the GitHub App files. A lane machine therefore has no
`accounts.d`. Until a person puts `accounts.d/<label>.env` on the machine,
each of these lanes on a lane machine refuses its claude call with rc 76.
This change ships no secret transport.

A3 proves that no key leaks. Neither fixture token and no `env/` or
`accounts.d` member is in any snapshot. The entrypoint writes no token and no
label into the worker env or into its env dir. With
`ACCOUNT_PROJECT_FOR_LANE=alert-triage=demo`, the label is `acct-demo`. With
`accounts.d/acct-demo.env` present, only demo's token is printed. With the
file absent, `project_account_exports` returns rc 3.

## Not carried: what blocks a flip

A per-file compare-and-set from N project runs would conflict on every tick
for these fleet-wide writes. A flip ticket must solve them first:

- appends to `logs/ALERTS.log` (alert-triage.sh:559, 1394, 1409, 1428,
  1504, 1689; alerts-medic.sh:384, 691, 705, 762; model-route.sh:98);
- `state/triage-prstate.json` (bin/triage-spool-retire.sh:140) and
  `state/alert-triage-expired-*.tsv` (bin/triage-spool-retire.sh:137);
- `state/alert-triage-cliff-parked.tsv` (alert-triage.sh:1640);
- `state/lane-noise-alert-triage.count` (bin/lib/lane-caps.sh:616);
- `state/responder/handled.json`, one JSON keyed `<project>:<key>` and
  rewritten under a lock (watchdog-responder.sh:134-141, 239, 257, 285,
  911-916). It is not a project-keyed TSV, so `@row` does not fit;
- `logs/medic.log` (alerts-medic.sh:53) and `logs/responder.log`
  (watchdog-responder.sh:74). Every project run appends to them. The lane log
  that rides back is `logs/<lane>.log`, and these two lanes log under other
  names;
- `state/alerts/*`, `state/alert-line-sent/*`, `logs/cost.csv`,
  `flags/alerted-*`, `flags/lane-caps-degraded-*`, `logs/lane-caps.log`,
  `logs/model-route.log`, `logs/agent-rules.log`;
- `state/stale-owed.json` rides whole (see above). A per-project filter for
  it needs a new directive in `bin/lib/lane-run-inputs.sh`.

Root paths and credentials that also block a flip:

- `bin/alerts-medic.sh:19` sets `HARNESS=/root/harness` with no condition,
  so it ignores the machine's `HARNESS`.
- The prompts name absolute `/root/harness` paths. For the responder these
  are `setsid /root/harness/bin/run-build.sh` and the build-queue and fly-pool
  dirs (watchdog-responder.sh:338, 364, 368-369). For medic they are
  alerts-medic.sh:775-779.
- `bin/fleet-conf.sh:64` reads `/root/harness/fleet.conf` before
  `bin/../fleet.conf` when `FLEET_CONF` is unset.
- The responder reads the board API token with `bin/internal-token-for.sh`,
  from `env/$p.env` (watchdog-responder.sh:405, 523). This is a second
  per-project credential, and a lane machine does not have it.

Secrets and machine-local state are never carried: `env/*`, `accounts.d`,
`tokens.d`, `locks/*`, `state/gh-*`, `state/settings-cache.json`,
`state/lane-gate/*`.

## The scratch runs

These are NOT hub runs. The build ran on a pool builder with no hub logs. Each
run stubbed agent-call, gh, curl and ssh, and pinned the clock. The lists are
`find <root> -newer <marker> -type f`, without the fixture's own stub files.

alert-triage, from `tests/llm-alert-lanes-offhub.bh-6720-test.sh` A2 with
`LRI_INVENTORY_OUT` set:

- Command: `bash $M/bin/alert-triage.sh demo` on the machine root that
  `lri_fetch` built from the published snapshot.
- Start 2026-10-14T18:39:58Z, rc 0. The model call ran once.
- Written:
  - in `.rw`: `state/alert-triage/demo/{alert-families.json,
    alert-fix-prs.json, inbox.tsv, inbox.tsv.lock}`;
  - the lane log: `logs/alert-triage.log`;
  - not carried: `flags/lane-caps-degraded-alert-triage-*` (3),
    `logs/lane-caps.log`, `logs/model-route.log`,
    `state/lane-noise-alert-triage.count` and its `.lock`;
  - machine-local: `locks/alert-triage-demo.lock`,
    `locks/triage-prstate.lock`, `state/lane-gate/*` (3).

alerts-medic, with the fixture of `tests/alerts-medic-per-project.bh-5942-test.sh`:

- Command: `bash $H/bin/alerts-medic.sh demo`, with one console alert for
  demo.
- Start 2026-10-14T18:36:14Z, rc 0. The model call ran once.
- Written:
  - in `.rw`: `state/alerts-medic/demo/{medic-families.json,
    medic-parked.json, medic-seen.txt}`, `logs/medic-run.demo.txt`;
  - not carried: `logs/medic.log`, `flags/lane-caps-degraded-medic-*` (2),
    `logs/lane-caps.log`, `logs/model-route.log`;
  - machine-local: `locks/alerts-medic-demo.lock`, `state/lane-gate/*` (3).

watchdog-responder, with the fixture of
`tests/responder-per-project.bh-5942-test.sh`:

- Command: `bash $H/bin/watchdog-responder.sh demo`, with one
  `state/stale-owed.json` entry for demo.
- Start 2026-10-14T18:36:05Z, rc 0. The decide call and the act call both
  ran.
- Written:
  - in `.rw`: `state/watchdog-responder/demo/{stale-history.json,
    stale-owed.json}`, `logs/responder-decide.demo.txt`,
    `logs/responder-run.demo.txt`;
  - not carried: `state/responder/handled.json` and its `.lock`,
    `logs/responder.log`, `flags/lane-caps-degraded-responder-*` (2),
    `logs/lane-caps.log`, `logs/model-route.log`;
  - machine-local: `locks/watchdog-responder-demo.lock`,
    `state/lane-gate/*` (3), `state/gh-budget/*` (2).
- The fixture had no `bin/internal-token-for.sh`, `bin/board-fetch.sh` or
  `bin/responder-fix/escalate-missing.sh`. The board fetch and that remedy
  did not run.

## Turn-on, by a person

This change sets no row. To run one lane on lane machines:

1. Put `accounts.d/<label>.env` for each project the lane runs into the lane
   machine's env dir. Until then each run refuses its claude call with rc 76.
2. Solve the flip blockers above.
3. Set `lane_placement.<lane>=fly`.
4. Run `bin/lane-snapshot-publish.sh --lane <lane>` on the hub before each
   dispatch. Its cron (`cron/lanes/579-lane-snapshot-publish.cron`) passes no
   `--lane`, and the script defaults to blocked-resolver.
5. Check `GET /api/lane-runs/metrics?hours=1` (the `lanes` rows) and
   `GET /api/lane-runs?lane=<lane>` for the lane's runs.

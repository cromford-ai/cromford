# Archie, whole-factory watch: one lever per incident, one ticket if it did not take (BH-4586, wave 4 of #4574)

Doc: ALERTS-STATE-MACHINE, DB-COORDINATION-SPEC, OPERATOR-SETUP

## What changed

A new hub lane, `archie-fm-watch` (`bin/archie-fm-watch.sh`, libraries in
`bin/lib/archie-fm-watch/`, registry `catalog/lanes.d/archie-fm-watch.json`,
cron `cron/lanes/727-archie-fm-watch.cron`, `7-57/10` behind `hub-lease.sh
check`, off the queue doctor's minute). Each tick it collects **findings** from
the alerts that already exist and from four sweeps, maps each finding to ONE
lever from a fixed allowlist, and files ONE ticket when an incident is still
open `archie.watch.escalate_s` after its lever ran.

Findings, by class (the class is the playbook `watch-<class>`):

| class | source | lever |
|---|---|---|
| build-stuck | open alert `stuck-work` (bin/stuck-work.sh) | `ack_alert`, routed to blocked-resolver / lane-reaper |
| review-unrescued | open alert `lane-reaper_<p>_<key>`, and the sweep of `builds/*/RESULT` (REVIEW_BLOCKED with no verdict, or ABANDONED_TIMEOUT with REAPED; no `.review-rescued`, no `.blocked-resolver-superseded`; older than `archie.watch.rescue_grace_s`) | `kick_lane review-rescue` with `RESCUE_ONLY=<project>` |
| pool-idle | open alert whose line starts `[fly-idle] ` | `file_ticket` (no machine stop) |
| disk | open alert `disk-high-<host>`, `disk-refuse-<host>`, `ph-tmpfull_<host>`; sweep `df -iP / /tmp` against `archie.watch.inode_pct` | this box: `run_cleanup` (`bin/disk-clean.sh`, foreground, `timeout 900`, once a tick); another box: `ack_alert`, routed to its own disk-clean |
| cron-install | open alert from `[orchestrator/fleet-propagate]` or a `[<box>] CRONTAB GAP/DRIFT/RENDER FAILED` line, older than `archie.watch.cron_install_s`; sweep: a `catalog/lanes.d/*.json` on main (the hub checkout, `${HARNESS_CHECKOUT:-/root/harness-checkout}`) that is wired, on the hub, has a `cron/lanes/<NNN>-<id>.cron` fragment whose body names its script (the expected set is what `render-cron.sh hub` emits, not `.cadence`, which is prose for lanes run via a wrapper or on demand), was added more than `cron_install_s` ago, and whose script no `crontab -l` line names | `kick_lane fleet-propagate` |
| deploy-drift | open alert `ph-deployworkers_<slug>` (run id and repo read from its line) or `ph-consolepagesdrift_hub` | `rerun_deploy`: REST `POST repos/<slug>/actions/runs/<id>/rerun-failed-jobs` only when that run is still the newest `deploy-workers.yml` run on main (any status) and its `head_sha` is main's head, because a re-run reuses the original run's sha and would roll a newer deploy back (otherwise the row closes `failed`, "superseded by run N"); the 201 only queues it, so the row is `requested`; or `bin/console-pages-deploy.sh` detached where `cloudflare.env` is (else `file_ticket`) |
| main-red | open alert `main-red-<slug>` whose line says `main is RED` / `STILL RED` | `kick_lane main-red-bisect` |
| pause-waiting | sweep: a builds/merges pause older than `archie.watch.pause_waiting_s` with work behind it (`rq_lines` for builds, a READY conductor row for merges) | `file_ticket` (never unpause) |
| triage-skip | open alert `untriaged-digest_<p>_<day>` or an untriaged-sweep line, for a fleet.conf project | `kick_lane triage` = box command `run_triage` to the project's owning box |
| cost-anomaly | open alert `ph-costrollupstale_hub`, `ph-costrate_*`, `ph-costratenoeval_*`, `ph-overcap_*`, `budget-stop_*`, a `cost-reconcile` line or a `[gh-quota]` line | stale rollup: `kick_lane cost-rollup`; the rest `ack_alert`, routed to the brake that already acts |

Alerts are matched on the id their detector's keyer produces
(`as_sanitize_id`, pipeline-health's `ph-<key>`, the `main-red-<slug>` collapse
rule) or on the START of the line, never on `alerts.family` (a 12-hex hash).
An alert is a finding only once it is `archie.watch.alert_min_age_s` old, so
the detector's own self-heal goes first. The default, 3000 s, is also past
alerts-medic's window: medic reads `new` rows older than 1200 s every 30
minutes, and an ack moves a row new -> triaged, which never returns to new. So
medic always gets one full pass at a row before the watch acks it; after the
ack, the watch's route (and its escalation ticket) replaces medic for that
incident. The incident is `<alert id>@<first_seen
epoch>` (a resolved-then-refired alert is a new incident), except
review-unrescued, where the alert and the sweep both use the build dir name, so
they are one row.

## Cadence, the model session and the two owed inputs (the operator, 2026-10-05/06)

- **Cadence.** Cron still fires every 10 minutes. A plain tick acts only when it
  is the first tick of its `archie.watch.interval_min` window of epoch minutes
  (D1 settings, seed 20, range 10..1440). At 20 the ticks at :07, :27 and :47
  act. The other ticks exit before the lock. `--class` and `--dry-list` are
  not gated. No state file holds the last tick.
- **Model session (`afw_session`).** The bash sweep runs on every acting tick at
  $0. After the findings loop, a plain tick starts at most ONE agent-call
  (stage `archie`, model from `model_routes stage.archie`). It starts only when
  the tick created a row (key `watch:session:new:<minute>:<mode>`), or once per
  UTC 3h block to walk the owed ledger (key `watch:session:owed:<block>:<mode>`).
  The row (playbook `watch-session`) is claimed before the call. The day cap is
  `archie.cap.watch-session` (seed 12, 0 = off). The prompt is
  `catalog/prompts/archie-watch.md` from BH-4760. Until that file exists, no
  session starts and the log says so. A non-blank answer goes to the operator through
  `bin/archie-tg-send.sh`, keyed on the row's key. A blank answer is silence.
- **owed-overdue.** `afw_sweep_owed` reads the OWED TO OPERATOR lines in
  `ARCHIE_FMW_STATE_MD` (default `/root/orchestrator/STATE.md`). A line whose
  `expected-by <ISO>` has passed is a finding. Lever `note`: one row per line,
  never escalated. The model session that the new row starts tells the operator.
- **metric-unreadable.** `afw_sweep_metric` reads `GET /api/initiatives`. An
  active initiative whose last check was `unreadable` is ONE `note` row on
  `I<id>`, then deduped.
- **Stopgap.** When this merges, remove the operator cron for
  `/root/orchestrator/bin/archie-sweep.sh` (7,27,47) on the hub. Otherwise both
  run.

## The ledger and the escalation

Every lever pull is an `archie_actions` row under `watch-<class>`, pr 0, key
`watch:<class>:<incident>:<lever>:<mode>`, claimed through wave 2's `afq_claim`
before the lever runs. `done` only on a verified success (REST 201, alert ack
200, or 409 for an alert already triaged, disk-clean rc 0, issue 201 with its
URL). Detached kicks and queued box commands are `requested`. Everything else
is `failed` with the reason. Observe mode writes `would_*` rows and nothing
else. Mode `off` (`archie.manage[.<project>]`, fleet-scope findings read
`archie.manage.hub`) skips the finding.

Before a claim the lane reads the key back (`GET /api/archie/actions?dedupe_key=`).
A lever row that is `done`, `requested`, `failed` or `would` and older than
`archie.watch.escalate_s`, for an incident that is still a finding this tick,
gets ONE `watch:ticket:<class>:<incident>:<mode>` row under `watch-ticket` and
one issue. A direct ticket (pool-idle, pause-waiting) is not escalated into a
second one. If filing it failed, it is retried once under `watch-ticket`.

`file_ticket` reads the open issues on `example-org/cromford` first, up to 10
pages, for the body marker `<!-- archie-fm-watch:<class>:<sha12 of incident> -->`.
A match is `done` with that URL and no new issue. A read that fails, or a tenth
page that is still full, files nothing. The issue has a fixed plain-English
title and body (what was seen, which lever ran and when, the evidence) and NO
label. Wave 5 owns ai-build filing.

## The allowlist

`afw_pull` is one `case` over `kick_lane` (review-rescue, fleet-propagate,
main-red-bisect, cost-rollup, triage), `run_cleanup` (hub only), `rerun_deploy`
(the two shapes above), `ack_alert` and `file_ticket`. Any other lever, or a
kick of a lane not on the list, is refused before any write and its row is
closed `failed`. The lane raises no alert of its own. Its one ALERTS line is
wave 2's stale-`started` line, now prefixed with the owning lane: `afq_alert`
prints `${AFQ_ACTOR}:`, and the stale line names `logs/${AFQ_ACTOR}.log` and
drops the PR link when the row's pr is 0. Under wave 2's default actor the text
is unchanged.

## Settings rows (worker/jobs/schema.sql, BH-4586 block)

Caps, per UTC day across the fleet, counting mode-on rows that are done or
requested (0 = off): `archie.cap.watch-build-stuck` 20, `watch-review-unrescued`
10, `watch-pool-idle` 5, `watch-disk` 10, `watch-cron-install` 6,
`watch-deploy-drift` 6, `watch-main-red` 10, `watch-pause-waiting` 5,
`watch-triage-skip` 10, `watch-cost-anomaly` 10, `watch-ticket` 5.

Thresholds: `archie.watch.escalate_s` 7200, `archie.watch.rescue_grace_s` 3600,
`archie.watch.cron_install_s` 1800, `archie.watch.pause_waiting_s` 7200,
`archie.watch.inode_pct` 90, `archie.watch.alert_min_age_s` 3000. An absent row
is its documented default (`afw_setting_default`, `afw_cap_default`). A row
that cannot be read, or is not a whole number, means no action on that check
this tick, with one log line.

The route (`worker/jobs/src/routes/archie-actions.js`) accepts the eleven
playbooks and the five levers with their `would_*` words, and pr 0 on a
`watch-*` playbook only.

## Commands

- `bin/archie-fm-watch.sh` — one tick (the cron line).
- `bin/archie-fm-watch.sh --dry-list` — print the findings, one TSV line each
  (`class subject incident project host alert_id opened evidence`). No row, no
  lever.
- `bin/archie-fm-watch.sh --class <class>` — one tick narrowed to one class.
- Off: `ARCHIE_FMW_ENABLED=0`, `flags/lane-off-archie-fm-watch`,
  `bin/harness-ctl.sh off archie-fm-watch`, or `archie.manage=off`.

## What it decided, and the other reading

- Pool idle is a ticket, never a machine stop: a stop can kill a live build.
- A pause is never lifted: someone set it for a reason the lane cannot see.
- A stuck build is acked and routed: blocked-resolver and lane-reaper own it.
- Another box's disk is acked and routed: there is no remote disk-clean verb.
- Inodes are measured on the hub only: there is no inode detector, and the
  ticket bars new alert families.
  The inode incident is `host:mount:UTC-day`, so an inode problem that
  outlasts a day gets one more disk-clean run and, after `escalate_s`, one
  more ticket per day, both under their daily caps.
- `READY-QUEUE.log` lines carry no timestamp, so "work waiting" is any ready
  line for the project now, not one newer than the pause.
- Escalation also covers a `failed` lever row, so a lever that failed still
  reaches a ticket instead of waiting silently.
- Tests: `tests/archie-fm-watch.bh-4586-test.sh` (drives the shipped lane) and
  `worker/jobs/test/archie-actions.bh-4586.test.js` (the route on the real
  schema).

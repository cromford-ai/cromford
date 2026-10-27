# Archie, manager authority and the daily factory report (BH-4588, wave 6 of #4574)

Doc: OPERATING, guide/04-archie

## What changed

### Manager authority

Archie's guardrail levers are now decision classes of their own, seeded
`delegated` (`worker/jobs/schema.d/202610270329-bh-4588-factory-manager.sql`):
`lever-enqueue`, `lever-dequeue`, `lever-fix-round`, `lever-rebuild`,
`lever-rebase`, `lever-re-review`, `lever-hold-label`, `lever-pause-row`,
`lever-iron-law-ack`, `lever-ticket`, `lever-alert-ack`. A decision on one is
mode `auto`: Archie acts and reports after. One overrule puts the class back to
`ask_first` (the BH-4067 rule, unchanged).

- `archie_sensitive` (`bin/lib/archie.sh`) scans a `lever-*` class for the hard
  limits only: the code constant `ARCHIE_HARD_LIMIT_RE` (a direct merge, a
  squash or land into main, a push to main including a `HEAD:main` refspec, a
  production DB write, a deploy, a release or rollback, money, cost or a
  spend-cap raise, a client-visible write, secrets, key rotation and
  migrations) plus `archie_client_board` (a write that names any board other
  than the harness board). Every other class keeps the full
  `ARCHIE_SENSITIVE_RE` scan. A hard limit on a lever class is still an ask.
- The protected classes (`merge`, `production`, `deploy`, `spend`,
  `client-board`, `unclassified`) keep their SQL CHECK and stay never
  delegable. They now mean the hard limits. The soul
  (`prompts/archie-soul.d/40-earned-autonomy.md`), the check prompt
  (`catalog/prompts/archie-check.md`, lines added only) and the delegate
  refusal reply in `bin/archie.sh` say so.
- `ARCHIE_HARD_LIMIT_RE` is a code constant on purpose, for the same reason as
  `ARCHIE_SENSITIVE_RE`: a settings write must not widen Archie's authority.

### The daily factory report

- `GET /api/archie/factory-report?day=YYYY-MM-DD[&project=][&limit=]`
  (`worker/jobs/src/routes/archie-factory.js`): mode, merges per project,
  queue health, stuck items and how they were cleared, tickets filed and
  shipped, spend vs caps, the one thing to know, and the day's
  `archie_actions` rows. Every section carries `ok`; an empty one carries
  `empty_reason`; a failed read is `{ok:false, error}`, never a 0. Seven
  statements a call: the settings read, then six reads in one `Promise.all`.
  `?limit=` over `archie.report.actions_limit` is a 400, not a clamp.
- The one thing, highest first: an open stop-the-line incident (added by the
  lane's renderer, which alone reads the stop-the-line table), failed actions,
  a project over its spend cap, open stuck items, else "Nothing needs you".
- New hub lane `archie-fm-report` (`bin/archie-fm-report.sh`, libraries
  `bin/lib/archie-fm-report/{render,stl}.sh`, cron
  `cron/lanes/729-archie-fm-report.cron` at `:03/:18/:33/:48`). From the first
  tick at or after `archie.report.send_hour_utc` (7) it renders yesterday's
  report as plain text (a fixed template, no model call) and sends it once
  through `archie-tg-send.sh "fm-report:<day>"`. With `archie.manage=off` the
  report still goes out, and its first line says Archie is off.
- The console screen `/factory` (`console-ui/src/screens/Factory.js`), linked
  from the STAFF roster note, shows the same answer with a day picker, the
  sections as a compact list and a sortable table of the day's rows with an
  evidence drill-down.

### The stop-the-line beat

On every tick the lane reads the open alerts and classifies them through
`catalog/archie-stop-the-line.tsv`: `main-red` (`main-red-*`, 60 min),
`queue-stalled` (`mc-window-stall-*`, 60 min), `box-down` (`pool-box-*`,
15 min), `spend-spike` (`ph-costrate_*`, `ph-overcap_*`, `budget-stop_*`,
0 min). `main-red-bisect_*` and `main-red-prs:*` are exclusion rows. Each
incident (`<alert-id>@<first_seen epoch>`) gets ONE beat through
`archie-tg-send.sh "stl:<incident>"`, not held for quiet hours, at most
`archie.stl.beats_per_tick` (3) a tick; the rest wait for the next tick. Mode
off sends no beat. The lane writes no `archie_actions` row and never acks an
alert.

## Knobs

Settings rows (seeded): `archie.report.send_hour_utc` 7,
`archie.report.stuck_max` 20, `archie.report.actions_limit` 300,
`archie.stl.main_red_min` 60, `archie.stl.queue_stall_min` 60,
`archie.stl.box_down_min` 15, `archie.stl.spend_spike_min` 0,
`archie.stl.beats_per_tick` 3. Lane knobs: `ARCHIE_FMR_ENABLED` (1),
`ARCHIE_FMR_ALERT_LIMIT` (500). New index: `idx_mq_batches_finished` on
`merge_queue_batches(finished_at)`.

## Commands

```bash
bin/archie-fm-report.sh render 2026-10-22   # the report text, sends nothing
bin/archie-fm-report.sh stl --dry-list      # the due stop-the-line incidents, sends nothing
```

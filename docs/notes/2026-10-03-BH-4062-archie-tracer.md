# Archie's tracer: initiative, check, message (BH-4062, wave 1 of #3966)

Doc: DB-COORDINATION-SPEC, MODEL-ROUTES, OPERATOR-SETUP

## What changed

The hub orchestrator is now **Archie**. Every orchestrator turn prompt (the v2
briefing and the survival brief) carries `prompts/archie-soul.md`, the soul
text from #3966, and every reply leaves `bin/orchestrate.sh` with a final
`Archie` line (`archie_sign` in `bin/lib/archie.sh`, applied once, right before
the one `deliver_reply "$OUT"`).

Archie keeps an **initiative register** in the jobs DB (`worker/jobs/schema.sql`,
tables `initiatives` and `initiative_events`; routes in
`worker/jobs/src/routes/initiatives.js`, bearer-gated like every route):

| route | what |
|---|---|
| `POST /api/initiatives` | create; same slug + same payload 200, different 409 |
| `GET /api/initiatives?id=` / `?status=&due_before=&limit=` | one row / the due list, `truncated` when capped |
| `POST /api/initiatives/check` | record a check slot `check:<id>:<due_at>`; `advance_to` closes it (CAS on `next_check_at`) |
| `GET /api/initiatives/events?key=` | the slot ledger, read before any model call |
| `POST /api/initiatives/reply` | the operator's approve / change / drop, keyed `reply:<id>:<command id>` |

Chat commands are answered by `bin/archie.sh intercept` from the
`# >>> archie intercept` block in `bin/orchestrate.sh`, with no model turn:

    Archie, track <goal> | metric: csv:logs/<file>.csv#<column>[@<column>=<value>] | every: 7d | escalate: change | links: <url> <url>
    Archie approve I3      Archie change I3 <what>      Archie drop I3

A new hub lane, `archie` (`cron/lanes/724-archie.cron`, `*/15`,
behind `hub-lease.sh check`), reads the due initiatives and for each one either
stays silent or sends ONE triaged `fleet_alert` beat: Archie's recommendation
first, then goal, metric, links and how to reply. It makes at most one model
call per due initiative (stage `archie`, model route `stage.archie`), only when
the escalation rule fires, and a tick with nothing due makes none. Every
attempt is written to the slot's ledger before the call, so one slot never
pays for more than `ARCHIE_MAX_ATTEMPTS` calls, and the beat body is fitted to
the worker's 4000-char cap (links that don't fit are counted, not dropped
silently), so a paid answer is never refused and bought again.

The first initiative is seeded: `tracer-first-slicing`, the decomposed rework
rate from `logs/outcome-rework-rollup.csv` (#3954, #3955, #3956), weekly, rule
`change`, first check 2026-10-05T07:00Z.

## Why

#3966 wave 1: the smallest path from "the operator asks Archie to watch something" to
"Archie tells the operator, once, when it matters".

## Not done here

- `/root/orchestrator/CLAUDE.md` on the hub is not edited. The soul ships in
  this repo as `prompts/archie-soul.md` (synced by `bin/harness-sync.sh`) and
  is injected into every turn prompt instead.
- `change` records the operator's note and decision; it does not edit the initiative.
- Metrics are `none` or a CSV column under `logs/` only. No shell, no HTTP: a
  chat message must never become code that runs on the hub.

## Operate

- Off: `ARCHIE_ENABLED=0`, `flags/lane-off-archie`, or
  `bin/harness-ctl.sh off archie`. Knobs: `catalog/lanes.d/archie.json`.
- Log: `logs/archie.log`, one `due= checked= beats= model_calls= skipped=` line
  per tick that had work.
- Seed check after deploy: `bin/jobs-client.sh` GET `/api/initiatives?id=1`.

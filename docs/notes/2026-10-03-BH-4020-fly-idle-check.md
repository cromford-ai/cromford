# 2026-10-03 — BH-4020: daily idle Fly machine alert

Doc: COST

**What changed.** A new hub lane, `bin/fly-idle-check.sh`, runs daily at 06:37Z
(`cron/lanes/724-fly-idle-check.cron`). It lists every machine in `FLY_ORG` and
flags the ones that are `started`, have been up more than `FLY_IDLE_HOURS`
(default 2) since their newest start event, and are held by nothing the harness
knows of: no `state/fly-pool/<p>/<mid>.json`, no `state/fly/<p>.json` naming it
with `<p>-active.json` beside it, and no claimed harness-jobs queue row carrying
it. Flagged machines go into ONE `logs/ALERTS.log` line per UTC day, marker
`state/fly-idle-check/<YYYYMMDD>`, each with its hourly burn from
`fly_price_per_s` (`bin/lib/fly-cost-row.sh`, BH-4018) x 3600, or
`burn unpriced` when the size is unknown. At most 20 are listed, then
`... and K more`. Apps past `FLY_IDLE_MAX_APPS` or whose machines could not be
read are named as `partial: K apps not checked`.

**Why.** The 2026-10-03 cost report counted 42 machines, 25 running, and idle
time was only visible after it had been billed (#3989).

**What it never does.** It sends GETs only. It never stops, destroys or POSTs
to a machine; stopping one stays a person's call, from the app/mid the alert names.

**Failure.** No `FLY_API_TOKEN`: one `not configured` log line, rc 0, no alert.
A failed apps read or no `fly-machines` endpoint: one ALERTS line naming why,
rc 1, no marker, so the next day retries. Never reported as "0 idle".

**Switches.** `flags/lane-off-fly-idle-check`; knobs `FLY_IDLE_HOURS`,
`FLY_IDLE_IGNORE_APPS`, `FLY_IDLE_MAX_APPS`, `FLY_IDLE_HTTP_TIMEOUT`,
`FLY_PRICES`, `FLY_IDLE_NOW` in `catalog/lanes.d/fly-idle-check.json`.
Pinned by `tests/fly-idle-check.bh-4020-test.sh`.

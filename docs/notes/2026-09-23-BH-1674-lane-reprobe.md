# 2026-09-23 — BH-1687 (BH-1674 part 2): a down runner lane is re-probed and clears itself

Doc: ALERT-REMEDIATION, SCHEDULER

## What was wrong

A runner lane (codex, openrouter, fireworks, grok) that failed the auth
canary was written to `state/claude-auth-down.txt` and then only looked at
again on the canary's next 6-hourly pass. Nothing said when it came back,
and a lane down for days re-nagged daily with no single standing record of
how long it had been gone or why.

## What it does now

`bin/lane-reprobe.sh` is a new hub lane (`*/5`, lease-gated,
`cron/lanes/705-lane-reprobe.cron`, registry `catalog/lanes.d/lane-reprobe.json`).
Each tick it:

1. Seeds a `state/lane-down/<box>-<lane>` record for any STATE lane line that
   has none, with `since` taken from the contiguous `flags/lanedown-*` run.
2. Probes the records that are due (fast/slow interval by outage age), oldest
   `last_probe` first, up to the cap and the deadline, logging `deferred N`
   for the rest.
3. On an ok probe calls `ld_recovered`: record, flag and STATE line removed,
   one `lane <lane> back on <box> after <dur>` line, both alert ids resolved.
4. On anything else calls `ld_mark` and logs `still down`; at 24h it sends
   ONE `lanedown-stale-<box>-<lane>` warn per outage and stamps `standing_at`
   only after `bin/lane-alert.sh` returns 0.

## Knobs

`LANE_REPROBE_FAST_S` 1800, `LANE_REPROBE_SLOW_S` 21600,
`LANE_REPROBE_BACKOFF_AFTER_S` 86400, `LANE_DOWN_STANDING_S` 86400,
`LANE_REPROBE_MAX_PER_RUN` 4, `LANE_REPROBE_DEADLINE_S` 600. All settable
through the lane's settings rows; a non-numeric value falls back to its default.

## What it does not change

The canary `bin/claude-auth-check.sh` is untouched and still edits the same
STATE file on its own schedule. Seeded lanes are first probed one interval
after the seed (up to 6h for an outage already past a day), because `ld_mark`
stamps `last_probe`.

Off switch: `bin/harness-ctl.sh off lane-reprobe` (`flags/lane-off-lane-reprobe`).

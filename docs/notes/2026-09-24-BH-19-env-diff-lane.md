# A new env-diff lane announces runner, billing, model and effort env changes

Doc: OPERATOR-SETUP

## What changed

BH-19 adds the `env-diff` lane: `bin/env-diff.sh`, registered in
`catalog/lanes.d/env-diff.json` and scheduled `*/15` on every box by
`cron/lanes/646-env-diff.cron`.

Each tick parses the top-level `*.env` files in the box's env dir and keeps the
keys `RUNNER_*`, `*_BILLING`, `*_MODEL` and `*_EFFORT`, one row per file and key.
It diffs them against `state/env-diff/snapshot.tsv`. Any difference goes out as
one `fleet_alert` with `"triaged":true`, naming the box and each change as
old→new (`∅` when absent). The akey is `envdiff:<box>:<hash of the change>`.

## Why

the operator, 2026-09-24: "A billing-mode change is an architecture change and must
never be silent." The ticket asked for this in `bin/fleet-heartbeat.sh` or a
small companion. BH-1031 deleted that script, so it's a companion lane.

`"triaged":true` is on purpose. It skips the alert state machine, quarantine and
both remediation tiers, so nothing on the box can settle the alert before a
human reads it. The console dedupes on the akey.

## What it touches

- State: `state/env-diff/snapshot.tsv` (written atomically, only after the
  alert was delivered or written to `logs/ALERTS.log` on a box with no console).
- Logs: `logs/env-diff.log`, and `logs/ALERTS.log` only when `beat.sh` answers
  rc 2 (no console configured).
- Switches: `flags/lane-off-env-diff`, `ENV_DIFF=0`. Knobs `ENV_DIFF_MAX_ITEMS`
  (20) and `ENV_DIFF_BOX` (hostname).

## Known gaps

- A value flipped and flipped back between two ticks is never seen.
- A lost snapshot re-baselines silently. Whatever changed while it was gone is
  not announced.
- The same key in `global.env` and `<project>.env` is two rows. The lane reports
  what each file says, not which value wins.

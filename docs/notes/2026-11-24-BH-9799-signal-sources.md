# BH-9799: per-project Sentry and PostHog sources

Doc: KEY-ROTATION, SENTRY-TRIAGE

## What changed
- New registry `catalog/signal-sources.d/<project>.json` and its reader
  `bin/lib/signal-source.sh`. One row now: `project-6-os` (Sentry org
  `project-6-llc`, project `project-6-os`, token `SENTRY_MK_API_TOKEN`;
  PostHog project `598179`, key `POSTHOG_MK_PERSONAL_API_KEY`, filter
  `properties.app = 'project-6'`). A row holds env names only.
- `bin/sentry-lookup.sh "<terms>" <project>` uses the project's org and token
  when the project has a row. Output format unchanged.
- `sentry-triage` runs one pass per Sentry source: the default source as
  before (bare ledger keys, same summary line), then each registry project
  (keys `<project>:<id>`, day row `<project>:<YYYY-MM-DD>`, tickets in the
  project's fleet.conf repo, list alert `sentry-triage-list-<project>`). An
  unreadable ledger stops the whole tick.
- New `bin/posthog-lookup.sh <project> "<hogql>" | --report api-failures|web-vitals`.
  Knobs in `catalog/lanes.d/_lib.posthog-lookup.json`.
- New `bin/signal-env-install.sh <project> <NAME>` (value on stdin), under
  `locks/harden-state.lock` with `--release` and `--rearm`. Knob in
  `catalog/lanes.d/_lib.signal-env-install.json`.
- `bin/lib/token-redact.sh` masks Sentry tokens (`sntry<x>_...`) and PostHog
  keys (`ph<x>_...`). The sentry-triage log, ticket title, ticket body and
  comment body pass through it (discovery-daily gets the same masking).
- The alert-triage and medic prompts name both readers.
- New fleet rule topic `rules/topics/19-app-signals.md`.

## Operator step
The hub has no copy of the project-6-os keys yet. Until an operator runs
`bin/signal-env-install.sh` on the hub (docs/KEY-ROTATION.md), the project-6-os
source writes one `project=project-6-os: SENTRY_MK_API_TOKEN unset; nothing read`
line per tick and makes no call.

## discovery-daily
discovery-daily sets no `ST_KEY_PREFIX` and no `ST_TOKEN`, so its keys and its
token are unchanged. Do not set `DISCOVERY_SENTRY_PROJ` for project-6-os while
the registry row has a `sentry` block (two lanes, two markers, two tickets).

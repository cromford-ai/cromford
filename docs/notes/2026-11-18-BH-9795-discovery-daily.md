# BH-9795: the discovery-daily lane, Sentry source (part 1 of 2)

Doc: DISCOVERY-DAILY

## What changed
- New hub lane `discovery-daily` (`bin/discovery-daily.sh <project>`, daily
  07:23 UTC). Per project it reads the discovery sources, drops known items in
  code, makes one no-tools model call per item that is left, and the rules
  table in `bin/lib/discovery/rules.sh` files an `ai-build` ticket, comments
  on an open candidate ticket, or marks noise.
- Part 1 source: Sentry (`bin/lib/discovery/sentry.sh`).
- `bin/lib/sentry-triage.sh` takes the parameters `ST_LANE`,
  `ST_MAX_ATTEMPTS`, `ST_OPEN_LABEL` and `ST_RAW_DIR` (each defaults to the
  sentry-triage value) and has five extracted helpers. The sentry-triage lane
  behaves as before; its suite is unchanged.
- `bin/discovery-setup.sh` writes the per-project settings rows.
- `bin/pipeline-health.sh` (hub section) raises one alert
  `discovery-missed:<project>:<date>` when a project with the lane on has no
  done run row for yesterday.
- ON for project-6-os: sources `sentry`, target `example-org/project-6`. The
  Sentry project slug is not set, so its runs log `sentry not-configured` and
  make no call until the lead sets it.

## Why
The ticket asks for one daily lane per project that turns found problems into
build tickets, with the decision in code and not in the model.

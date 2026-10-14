# Sentry issues become tickets (BH-5620, slice 4 of #5611)

Doc: OPERATOR-SETUP

## What changed

- New hub lane `sentry-triage` (`bin/sentry-triage.sh`, `bin/lib/sentry-triage.sh`),
  cron `11,41 * * * *` from `cron/lanes/466-sentry-triage.cron`. It reads the
  unresolved issues of Sentry project `cromford-harness` with `SENTRY_API_TOKEN`.
- Each issue with at least `SENTRY_TRIAGE_MIN_EVENTS` (3) events gets one model
  call (`model_routes` role `stage.sentry-triage`, seeded from `triage` rung 0).
  The answer is a new `ai-build` ticket, a comment on a matching open ticket, or
  noise. `hotfix` is added only above `SENTRY_TRIAGE_HOTFIX_EVENTS_24H` (50)
  events in 24 h. At most `SENTRY_TRIAGE_MAX_TICKETS_DAY` (5) new tickets a day.
- At most `SENTRY_TRIAGE_MAX_CALLS_DAY` (10) model calls a day, counted in the
  day row before each call. Noise, comment and failed results count too. So the
  day's spend is at most 10 x `SENTRY_TRIAGE_MAX_USD` (0.50), which is 5 USD.
  The ticket cap alone does not bound spend.
- Dedup before spend: `ledgers(kind=sentry-triage)` is read before any call. A
  regression gets one new pass on key `<id>:regressed`. An issue that was
  already regressed at its first pass gets no second pass. A failed call is retried
  at most 3 times, then `failed`.
- The ticket link is written back to the Sentry issue as a comment. A token
  without `issue:write` gets `writeback: skipped-403` and one log line.
- Kill switch: `flags/lane-off-sentry-triage` or the D1 pause row of the same name.

## What an operator must know

- `SENTRY_API_TOKEN` already exists on the hub with read scope. The writeback
  needs `event:write` or `issue:write` on it. Without that scope the lane still
  files tickets and logs `skipped-403`.
- The Sentry paths were not probed from the build box. The first hub tick after
  deploy is the live check: read `logs/sentry-triage.log` for the summary line.

Map: `docs/verification-map/sentry-triage.md`.

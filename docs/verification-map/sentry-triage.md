# Sentry triage (Sentry issues become tickets)

**What it is:** the hub lane `sentry-triage` (BH-5620). Every 30 minutes it
reads the unresolved issues of Sentry project `SENTRY_TRIAGE_PROJECT` (default
`cromford-harness`, org `SENTRY_ORG`, default `operator`) with
`SENTRY_API_TOKEN`, the auth `bin/sentry-lookup.sh` uses. Each issue with at
least `SENTRY_TRIAGE_MIN_EVENTS` events gets one model call and one outcome: a
new `ai-build` ticket, a comment on a matching open ticket, or noise.

**How a user reaches it:** there is **no UI route**. The knobs reach the
console settings page through `GET /api/lanes/registry` after the next worker
deploy.

- trigger: `cron/hub.cron`, `11,41 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/sentry-triage.sh`
  (source `cron/lanes/466-sentry-triage.cron`, rendered by `bin/render-cron.sh`)
- by hand on the hub: `/root/harness/bin/sentry-triage.sh`
- switch: `flags/lane-off-sentry-triage` (`bin/harness-ctl.sh off sentry-triage`),
  the D1 pause row of the same name, or `flags/all-off`. The gate runs before
  any Sentry or GitHub request.
- lock: `locks/sentry-triage.lock`, `flock -n`, so a second instance exits 0
- model: `model_routes` role `stage.sentry-triage` (seeded from `triage` rung 0
  by `worker/jobs/schema.d/0014-bh-5620-sentry-triage-route.sql`)

**Ledger:** `ledgers(kind=sentry-triage)`, key `<sentry issue id>` or
`<id>:regressed`. Status `retry` or `diagnosed` is open; `ticketed`, `noise`
and `failed` are terminal. The day row `ledgers(kind=sentry-triage-day,
key=<YYYY-MM-DD>)` holds `{filed: [<sentry ids>], calls: <n>}` for that UTC
day: the ids filed (`SENTRY_TRIAGE_MAX_TICKETS_DAY`) and the model calls
started (`SENTRY_TRIAGE_MAX_CALLS_DAY`, counted before each call). A filed
ticket body and a posted comment end with `<!-- sentry-issue: <key> -->`.
The worker cuts a detail at 4000 chars. The lane cuts the diagnosis text
fields first, so a stored detail stays under 3900 bytes and still parses
(`cut` in the detail is the field limit used).

**Log** `logs/sentry-triage.log`, one summary line per tick:
`<ISO> sentry-triage issues=<n> below_min=<n> terminal=<n> called=<n> filed=<n> commented=<n> noise=<n> failed=<n> capped=<n> healed=<n>`.
Other lines: `sentry token unset; nothing read`, `issue list failed (HTTP <c>)`,
`cap SENTRY_TRIAGE_MAX_TICKETS_DAY=<n> reached; <key> not triaged`,
`cap SENTRY_TRIAGE_MAX_CALLS_DAY=<n> reached; <key> not triaged`,
`<key> detail over 3900 bytes; the diagnosis text was cut to <n> chars`,
`<key> stored diagnosis unreadable ...; failed {why: diagnosis-lost}`,
`<key> comment already on #<n> (marker); not posted again`,
`cap off (SENTRY_TRIAGE_MAX_USD=0)`, `no route: stage.sentry-triage ...`,
`ledger unreadable; no calls this tick`, `open issue list unverifiable`,
`sentry token lacks issue:write (HTTP <c>); writeback skipped for <id>`.
Alerts (warn, `bin/lane-alert.sh`): `sentry-triage-list` and
`sentry-triage-ledger`, at most one each per tick.

**Per-project sources (BH-9799):** after the default source, the lane runs
one pass for each fleet project with a `sentry` block in
`catalog/signal-sources.d/<project>.json` (reader `bin/lib/signal-source.sh`).
That pass uses the row's org, slug and token (the row's env name, from the
environment or parsed from `env/<project>.env`), files in the project's
`fleet.conf` repo, and keys the ledger `<project>:<id>`,
`<project>:<id>:regressed` and day row `<project>:<YYYY-MM-DD>`. Its summary
line is `<ISO> sentry-triage project=<p> issues=...`, its list alert is
`sentry-triage-list-<p>`. No token: `project=<p>: <TOKEN_ENV> unset; nothing
read`. No fleet.conf repo: `project=<p>: no fleet.conf repo; nothing read`. An
unreadable ledger stops the whole tick. Log lines, ticket titles, bodies and
comments go through `token_redact`. `bin/sentry-lookup.sh '<terms>' <project>`
reads the same row. The PostHog reader is `bin/posthog-lookup.sh <project>
"<hogql>" | --report api-failures|web-vitals`. Keys and homes:
`docs/KEY-ROTATION.md`. Suites: `tests/sentry-triage-multi.bh-9799-test.sh`,
`tests/sentry-lookup-project.bh-9799-test.sh`,
`tests/posthog-lookup.bh-9799-test.sh`.

**What usually lies:**

- One regression pass per issue in total. A third regression after a
  `<id>:regressed` row exists gets nothing. This is by design. An issue that
  was already regressed at its `<id>` pass (detail `regressed: true`) gets no
  `<id>:regressed` pass.
- A `diagnosed` row is a paid diagnosis waiting on a post: a failed create or
  comment, or the day cap. The next tick acts on it with no new call. It
  fetches the latest event and log lines again, so the post carries that
  issue's own evidence.
- `writeback: skipped-403` in the row detail is the token scope (no
  `issue:write`), not a lane failure. The row stays `ticketed`.
- The lane log lines are read only when the event's `box` tag is the hub. An
  event from another box shows `log for lane <l> is on box <b>; not read from the hub`.
- The Sentry REST paths were not probed from the build box (no token there).
  The first hub tick after deploy is the live check.

**Verify:** `HARNESS_TEST_SANDBOX=1 bash tests/sentry-triage.bh-5620-test.sh`
drives the real driver against a scratch `$HARNESS` with a stub Sentry API, a
stub model runner and a file-backed ledger. Live: on the hub, run
`/root/harness/bin/sentry-triage.sh` once with `LLM_LANE_ENABLED=0`, then read
the summary line in `logs/sentry-triage.log`.

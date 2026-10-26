# GitHub quota gauge

**What it is:** how much of each GitHub token's REST and GraphQL budget is left,
pushed into `fleet_status`, plus one alert before the wall instead of at it.
`bin/lib/gh-budget.sh` pages when a bucket hits ZERO — which is after the lane
has already failed — and until BH-426 nothing anywhere carried the number in
between. Three parts:

- `bin/gh-token.sh --status [--json]` — one row per token this box holds (one per
  App installation cache file, one for the default PAT, one for the admin PAT,
  deduped by token value), each with REST and GraphQL `remaining/limit` and both
  reset times. A bucket that did not parse reports `0/0` with `unreadable` set,
  never `?/?` and never as headroom. The `--json` rows end with `credential`
  (BH-4717.2): `app-installation:<installation_id>` for an App row,
  `app:<owner/repo>` when its cache has no installation id, and the identity for
  a PAT row. The text form does not carry it.
- `bin/lib/gh-quota.sh` — `gh_quota_rows` (the validated array), `gh_quota_alert_pct`
  (the threshold), `gh_quota_alert_dedupe_s` / `gh_quota_alert_band_pct` (the
  dedupe), `gh_calls_top` (the busiest callers), `gh_quota_alert` (the ALERTS
  line, one per credential: the low rows are grouped on `credential // identity`
  and the worst row gives the numbers). Sourced by `bin/fleet-status-push.sh`; it consumes the `--json`
  rows, so no token value can reach it.
- the counter in `bin/lib/gh-limit-logger.sh` — one line per wrapped `gh` call,
  which is what makes "the top three scripts by call count" answerable at all.
  Since BH-8334 a `gh api -i -X <M> <path>` call (the shape `gh_rest` sends)
  gets a 5th field, `<METHOD>:<template>`, and `gh_calls_top_endpoints [caller]
  [n=10] [window=3600]` in `bin/lib/gh-quota.sh` prints `<count> <METHOD>:<template>`,
  busiest first.

**How an operator reaches it:** the hub's `bin/fleet-status-push.sh`
(`cron/lanes/270-fleet-status-push.cron`, \*/10, behind `bin/hub-lease.sh check`)
pushes the rows as `gh_quota` beside the existing `quota` block and then runs the
alert. Nothing renders it in Mission Control yet; it is read from the snapshot
and from `logs/ALERTS.log`.

**How to drive it:**

| what | how |
|---|---|
| the whole feature (six sections, three mutants) | `HARNESS_TEST_SANDBOX=1 bash tests/gh-quota.bh-426-test.sh` |
| one line per credential, the 2h/band dedupe, the `credential` field | `HARNESS_TEST_SANDBOX=1 bash tests/gh-quota-credential.bh-4717-test.sh` |
| `--status` beside the eleven per-project lanes | `bash tests/gh-default-auth-lanes-test.sh` |
| the 5th field and `gh_calls_top_endpoints` (BH-8334) | `HARNESS_TEST_SANDBOX=1 bash tests/gh-calls-path.bh-8334-test.sh` |
| the `gh` wrapper's transparency the counter rides on | `bash tests/gh-default-identity-test.sh` (§4) |
| the push it lands in | `bash tests/fleet-status-push-fields-test.sh`, `HARNESS_TEST_SANDBOX=1 bash tests/fleet-status-lease-alert.bh-1000-test.sh` |

**Verify it works on a live box (read-only):**

```bash
bin/gh-token.sh --status
bin/gh-token.sh --status --json | jq 'map({identity,credential,rest_remaining,graphql_remaining,resets_at})'
ls logs/gh-calls/                      # one file per hour, pruned at 180 minutes
(. bin/lib/gh-quota.sh; gh_calls_top_endpoints merge-conductor.sh 10 3600)   # the top 10 conductor endpoints, last hour
tail -n 20 logs/gh-quota.log           # why a gh_quota key was absent, if it was
grep '\[gh-quota\]' logs/ALERTS.log    # the low-budget lines
```

On the hub, the pushed key itself: `jq .gh_quota` over the newest `fleet_status`
beat (the console's fleet row, or the watchdog's `/status`).

**Files it owns on a live box:**

- `logs/gh-calls/<YYYYMMDDHH>.log` — `<epoch> <caller> <argv1> <argv2> [<METHOD>:<template>]`,
  one line per wrapped `gh` call, append-only. The 5th field (BH-8334) is
  written only when argv1 is `api` and argv2 is a flag. The template drops the
  query string and a leading `/`, writes `repos/{o}/{r}`, `{n}` for an all-digit
  segment, `{sha}` for a 40-hex segment or a 7-39 char hex segment with a digit,
  and `{ref}` for everything after `heads/`, `branches/` or `compare/`. A plain
  `gh api <path>` line stays 4 fields. Pruned at 180 minutes by the first writer
  into a new hour; no cron line and no other reader. The hour in the NAME is
  rotation only — readers glob the directory and filter on the epoch.
- `flags/alerted-gh-quota-<credential>` — the alert dedupe, one per credential,
  holding `<epoch> <pct>` of the last line. An empty or unparseable flag (the
  pre-BH-4717.2 `alerted-gh-quota-<identity>-<reset>` files are empty) reads as
  no flag. Pruned by the alerter at `max(180, gh_quota_alert_dedupe_s/60 + 60)`
  minutes.
- `logs/gh-quota.log` — `helper-missing|helper-failed|nonjson`, an unusable knob
  value, and every unreadable token. This is the file that says WHY `gh_quota` is
  not in a push.
- `logs/ALERTS.log` — one line per credential:
  `[gh-quota] GitHub quota low for app-installation:42 (shared by 3 repos: Org/a, Org/b, Org/c): rest 750 of 5000 left (15% left), graphql 4000 of 5000 left (80% left), resets at <iso> — top callers last hour: …`.
  More than three repos add ` +<k> more`; a one-repo installation reads
  `(repo <owner/repo>)`; a PAT or an `app:<owner/repo>` credential has no clause.

**Knobs:** all via `setting_get`, seeded in `worker/jobs/schema.sql` and
editable in the app, the code constant only as the fallback:
`gh_quota_alert_pct` (20, 1..99), `gh_quota_alert_dedupe_s` (7200, 60..86400)
and `gh_quota_alert_band_pct` (10, 1..99). A value outside its range, or a
non-integer, is logged once per tick and ignored rather than clamped.

**What must never regress:**

- `gh_quota` is ABSENT when the helper could not answer — never `null` (a
  consumer's `Number()` reads that as 0) and never `[]` (which reads as "this box
  holds no tokens"). The dead-man push and the console beat must survive every
  failure of this block, and the alert runs after both.
- Unknown is logged, never paged: an `unreadable:true` row and a bucket with
  `limit == 0` do not alert. 0/0 is not "0% left".
- Exactly at the threshold is not below it (`pct < threshold`).
- One line per credential per `gh_quota_alert_dedupe_s` (2h), sooner only when
  its worst percent fell to the flagged one minus `gh_quota_alert_band_pct` (10)
  or lower. Repos sharing an App installation never page separately. The line
  is written BEFORE the flag, so a crash can repeat a line and can never stamp a
  credential as alerted undelivered.
- No token value reaches `--status` output, the pushed payload, `logs/ALERTS.log`
  or any file under `logs/`.
- The merge path issues no `gh pr view` per PR: one list per harness author plus
  one REST read per PR, measurable in `logs/gh-calls/`.

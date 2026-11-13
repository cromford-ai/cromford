# GitHub App quota sustained alert, and requests per merged PR (BH-9455)

**What it is:** two parts of BH-9417's last slice.

1. `bin/gh-quota-sustained-alert.sh`, a hub lane at `19 * * * *`. For each of
   the last `GH_QUOTA_ALERT_HOURS` (3) complete UTC hours it reads the fleet
   GitHub-call ledger, one hour per request:
   `GET /api/metrics/gh-ledger?since=<hour>&until=<hour>` on harness-jobs. Per
   App bucket (`meter` `app` or `app-<id>`, `resource` `core`, `-` or empty) it
   sums `counted` over every box. The limit is the largest positive
   `limit_max` of those rows, else `GH_QUOTA_ALERT_LIMIT` (7050). When the
   bucket is at or above `GH_QUOTA_ALERT_PCT` (60) of its limit in EVERY hour,
   it writes ONE warn line to `logs/ALERTS.log` per UTC day:

   ```
   [gh-quota-sustained-alert] GITHUB QUOTA SUSTAINED: App bucket app-1 counted >= 60% of its limit for 3 full hours: 2026-10-20T07 4301/7050 (61%), 2026-10-20T08 4301/7050 (61%), 2026-10-20T09 4301/7050 (61%). Read bin/gh-ledger-report.sh --last 24h --top 30 --per-merged-pr on the hub. …
   ```

2. `bin/gh-ledger-report.sh --per-merged-pr`: one more line after the report,
   `per_merged_pr=<n> counted=<c> merged=<m>`. `merged` is one `search/issues`
   read per registry repo through `gh_rest`. A repo it cannot read prints
   `per_merged_pr=unknown (<repo> unreadable)`, never a number. Without the
   flag the output does not change.

**Why it exists:** on BH-9417's measured days the App bucket ran near its
hourly limit for hours, and nothing said so until builds stopped on 403s.
The per-merged-PR number is BH-9417's observable outcome.

**How to drive it:**

| what | how |
|---|---|
| the lane suite (curl-stubbed worker, a `gh` stub that must never run) | `HARNESS_TEST_SANDBOX=1 bash tests/gh-quota-sustained-alert.bh-9417-test.sh` |
| the report suite (seam file, stubbed `gh_rest`) | `HARNESS_TEST_SANDBOX=1 bash tests/gh-ledger-report.bh-9417-test.sh` |
| on the hub, once | `/root/harness/bin/gh-quota-sustained-alert.sh hub; tail -1 /root/harness/logs/gh-quota-sustained-alert.log` |
| the number | `/root/harness/bin/gh-ledger-report.sh --last 24h --top 30 --per-merged-pr` |

**Knobs:** on the `gh-quota-sustained-alert` lane: `GH_QUOTA_ALERT` (1; 0 =
off), `GH_QUOTA_ALERT_PCT` (60), `GH_QUOTA_ALERT_HOURS` (3),
`GH_QUOTA_ALERT_LIMIT` (7050), `GH_QUOTA_ALERT_MARKER_DAYS` (30),
`GH_QUOTA_ALERT_NOW` (env only, a test seam). Off:
`flags/lane-off-gh-quota-sustained-alert` or
`bin/harness-ctl.sh off gh-quota-sustained-alert`. Report seam:
`GH_LEDGER_REPORT_MERGED_FILE` (`repo<TAB>count` lines).

**What must never regress:**

- **Zero GitHub API calls from the lane.** The suite fails if `gh` runs.
- **Buckets never add.** `pat-*`, `graphql-*`, `search` and `graphql` rows do
  not count; two App buckets are judged one by one.
- **Unreadable is not quiet-and-wrong.** A failed read, no `.rows`, or a
  truncated answer under the threshold logs `hour=<H> unreadable why=…` and
  writes no alert and no marker.
- **Once per UTC day.** Marker `state/gh-quota-alert/<day>`, written only after
  the ALERTS line lands; pruned after `GH_QUOTA_ALERT_MARKER_DAYS`.
- **No number over a partial merged count** in the report.
- **rc 0 always** from cron; one `logs/gh-quota-sustained-alert.log` line per run.

# App quota sustained alert and requests per merged PR (BH-9455)

Doc: GH-REST

## Why

BH-9417 measures the fleet's GitHub spend. On its measured days the App
installation bucket ran near its hourly limit for hours. Nothing said so until
builds stopped on 403s. BH-9417's observable outcome is "GitHub requests per
merged PR", and no command printed that number.

## What changed

1. `bin/gh-ledger-report.sh --per-merged-pr` prints one more line after the
   report: `per_merged_pr=<n> counted=<c> merged=<m>`. `counted` is the TOTAL
   counted of the same window. `merged` is one `gh_rest GET search/issues`
   read per registry repo (`bin/fleet-conf.sh`), after `gh_repo_use_token`.
   A repo that cannot be read prints `per_merged_pr=unknown (<repo> unreadable)`.
   0 merged prints `per_merged_pr=n/a (0 merged)`. Without the flag the output
   does not change. Test seam: `GH_LEDGER_REPORT_MERGED_FILE`.
2. `bin/gh-quota-sustained-alert.sh` is a new hub lane at `19 * * * *`
   (`cron/lanes/713-gh-quota-sustained-alert.cron`). It reads the fleet
   gh_ledger for the last `GH_QUOTA_ALERT_HOURS` (3) complete UTC hours, one
   hour per request. When an App bucket (`app`, `app-<id>`, resource `core`)
   is at or above `GH_QUOTA_ALERT_PCT` (60) of its limit in every hour, it
   writes one warn line to `logs/ALERTS.log` per UTC day. The limit is the
   ledger's `limit_max` for that bucket and hour, else `GH_QUOTA_ALERT_LIMIT`
   (7050). Day markers live in `state/gh-quota-alert/<day>` and are deleted
   after `GH_QUOTA_ALERT_MARKER_DAYS` (30). The lane makes 0 GitHub calls.
3. Knobs: `catalog/lanes.d/gh-quota-sustained-alert.json`.

## Readings chosen

- The limit comes from the ledger rows of the same answer, not from the
  gh-budget cache. That cache is keyed by token, and a hub cron with no
  `GH_TOKEN` reads `pat-default` (5,000/h).
- Each App bucket is judged alone. Two installations have two limits.
- A failed read, an answer with no `.rows`, or a truncated answer under the
  threshold is `unreadable`: no alert, no marker, one log line. There is no
  local-ledger fallback.

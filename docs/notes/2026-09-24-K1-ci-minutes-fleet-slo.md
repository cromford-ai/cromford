# K1: a CI job-minutes watch, and bin/fleet-slo.sh finally on a cron line

Doc: CI-RUNNERS

## What changed

- **`bin/ci-minutes-watch.sh`** (new hub lane, `23 */6 * * *`): estimated
  billed CI job-minutes over 24h, per `fleet.conf` repo, from GitHub's run and
  job data (MonkCI has no usage API the fleet can reach). Budgeted: pages +
  sample reads per repo, skipped when the bucket is low; ratios per workflow,
  busy repos extrapolated from `total_count`. Over `CI_MINUTES_DAY_MAX` (25,000) it pages critical once a day via
  `bin/lib/page-critical.sh`.
- **`bin/fleet-slo.sh` is scheduled DARK** (`cron/lanes/716-fleet-slo.cron`,
  `*/10 --dry-run`, hub-lease gated: logs every breach, pages nothing — no
  hysteresis yet, thresholds unverified) and registered as the `fleet-slo` lane with the
  standard lane gate. docs/SLO.md said "cron */10" since 2026-09-15; no
  fragment ever ran it.
- `bin/lib/page-critical.sh` ships here too, byte-identical to the copy in the
  K1 cost-containment PR, so either PR can land first.

## Why

The 2026-09-24 runaway / silent-stop analysis: MonkCI billing ~120K
minutes/day with only the invoice to say so, and a fleet-SLO detector that was
built and documented but never run.

## Owed proof

Driven in a scratch tree with a fake `gh` (`tests/ci-minutes-watch.k1-test.sh`)
and the lane-registry and fleet-slo suites. Not observed live: after sync, the
hub should show `logs/ci-minutes-watch.log` lines at :23 every 6h and
`logs/fleet-slo.log` every 10 minutes.

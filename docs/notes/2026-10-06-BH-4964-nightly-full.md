# A daily full CI run on main, and its red filed as a map gap (BH-4970, slice 3 of BH-4964)

Doc: MERGIFY, COST

## What changed

- New hub lane `ci-nightly-full` (`bin/ci-nightly-full.sh`, registry
  `catalog/lanes.d/ci-nightly-full.json`, cron `cron/lanes/726-ci-nightly-full.cron`),
  both lines behind `hub-lease.sh check`. Kill: `bin/harness-ctl.sh off ci-nightly-full`.
- `dispatch` (hourly at :17) starts ONE `gh workflow run harness-ci.yml --ref main`
  per UTC date, from the first tick at or past `CI_NIGHTLY_FULL_HOUR` (default 3,
  so 03:17). A `workflow_dispatch` run is FULL in `bin/ci-plan.sh`. It skips,
  with a `dispatch: skip <reason>` line in `logs/ci-nightly-full.log`, when:
  the hour has not come; today's `run.json` exists; `flags/automerge-disabled`
  exists; `bin/lib/gh-budget.sh` says the bucket is low; an open PR carries
  `merge-queue` (or that read fails); another tick holds today's claim.
- The claim is `mkdir state/ci-nightly-full/<date>`. `run.json`
  (`{date, sha, dispatched_at, run_id}`) is written only after gh accepts the
  dispatch. A failed dispatch (rc 75 included) removes the claim, writes one
  ALERTS line per date, and the next hourly tick retries. A claim with no
  `run.json` older than 10 minutes is reclaimed.
- `collect` (hourly at :41) reads each dispatched date of the last
  `CI_NIGHTLY_FULL_LOOKBACK_DAYS` (default 3). Success writes
  `state/ci-nightly-full/last_green_sha`. Cancelled, skipped and neutral are
  not a red. Any other completed conclusion is a red:
  - the failed suites are the `--- tests/<x> rc=<n != 0>` lines in the failed
    shard jobs' logs, read over REST (at most `CI_NIGHTLY_FULL_MAX_LOGS`, default 8).
    The ticket named `trace-verdict-*` artifacts; none exist (the shards upload
    `verdict-<shard>`, counts only), and the suite lines are in the job log;
  - the changed files are `last_green_sha..sha`, or `sha~20..sha` when there
    is no recorded green run or it is not an ancestor, said in the body; at
    most 200 files are checked, and a cap that bites is said;
  - a changed file is missed for a suite when the red sha's own
    `bin/test-impact.sh select --changed <file> --map-only --why` has no row for
    that suite. The map is built once per red (`map --out`, then `--map`). A
    row of kind `full` is the corpus fallback, not the map, so it never counts
    as covered. A select that fails is listed as "map unreadable".
  - one issue, marker `<!-- harness-full-red -->`, title `Daily full CI run is
    red on main`, labelled `ai-build` (read back, added once if GitHub dropped
    it), or a comment on the open one, found over every page; a comment never
    adds the label. `ticketed` (the URL) and `done` are written only after gh
    returns the URL; a failed filing or a failed open-issue list read is one
    ALERTS line per date and the next collect retries.
- A run whose id is still not visible 6h after the dispatch is marked `lost`
  with one ALERTS line.

## Neighbours

- `bin/main-red-detector.sh` reads every run on main except `schedule` events,
  so a red full run counts there too, the same as a red push run of that sha
  would. This lane does not change the detector.
- `harness-nightly.yml` + `bin/nightly-ticket.sh` use the marker
  `harness-nightly-red`; the two tickets never comment on each other.
- The GitHub identity is `gh_default_auth_for_slug` (App token when mintable).
  `gh workflow run` needs `actions: write` on that identity; without it the
  dispatch fails and pages once a day.

Tests: `tests/ci-nightly-full.bh-4964-test.sh`.

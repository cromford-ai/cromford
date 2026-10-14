# The flaky-tier lane can release a quarantine row again (BH-4321)

Doc: FLAKY-TESTS

## What changed

- `bin/flaky-tier.sh` now sources `bin/lib/gh-ci-read.sh` with its other
  required libs, and its guard requires `gh_ci_api`. A missing one stops the
  lane with rc 1 and `flaky-tier: cannot load bin/lib/gh-ci-read.sh`.
- Each stderr line of `ft_release` now goes to `logs/flaky-tier.log` (and to
  stdout) before the tick line. Example: `ft_release: nightly run listing
  unparseable, releasing nothing`.

## Why

The lane never sourced `gh-ci-read.sh`. On every tick `ft_release` found
`gh_ci_api` undefined and released nothing. It wrote the reason to stderr only.
The lane dropped that stderr, and `cron/lanes/455-flaky-tier.cron` sends the
lane's own stderr to `/dev/null`. So `tests/share-mirror-clean-test.sh` and
`tests/share-publish-clean.bh-795-test.sh`, quarantined on 2026-10-04, stayed
`active=1` after 5 clean scheduled nightlies, and no log said why.

## What it touches

- Lane: `flaky-tier` (hub, 09:20Z daily). The next tick after the hub sync
  releases each `flaky-tier` or `main-red-bisect` row that has
  `FLAKY_TIER_RELEASE_CLEAN` clean nightlies. The decision logic in
  `bin/lib/flaky-tier-release.sh` did not change.
- Test: `tests/flaky-tier-release-wiring.bh-4321-test.sh` drives the real lane
  with its real bin closure through a release.

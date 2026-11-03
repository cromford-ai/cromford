# Lead review: E2E is a ratchet (BH-7941)

Doc: E2E-POLICY

## What changed

- The lead review prompt has a new `## Main E2E` section, after
  `## Live probes`. `bin/lib/e2e-main-baseline.sh` reads main's newest
  completed E2E-class run (push or nightly schedule) and the head's. It lists
  the failing Playwright specs red on both and red on the head only. It loads
  through a new `bin/lib/lead-review/libs.d/` fragment.
- The lead checklist is v11. Item 17: an E2E failure is a BLOCK only as a
  regression against main. Red on main too is a NOTE with a follow-up. One
  full E2E run is enough evidence.
- `rl_cap` (lens lead only) demotes an E2E finding that says the test is red
  on main (or the nightly) too, or that asks for "N full runs" or a per-spec
  table, before the ALWAYS-BLOCK floor. Phrases:
  `catalog/review-e2e-ratchet.tsv`. A failure that names no main or nightly
  stands. An evidence ask on a red head (`e2e-head-red` row) or with a
  `core-flow-broken` tag stands.
- The phrase is not the proof. `rl_cap --e2e <file>` reads the `## Main E2E`
  body. A "red on main too" line demotes only when every spec file it names
  is in the measured pre-existing list and none is a regression. No spec
  name, no readable main run, or a weakened test: the line stands.

## Why

A Playwright spec already red on main, or a missing "3 full runs" table,
kept E2E PRs at BLOCK. The `red-build` class matched `fails on main` text, so
the review level cap kept the line standing whatever the prompt said.

This is the rebuild of PR #7963. That PR added a source line to
`bin/lead-review.sh` and was red on `list-file-lint` (BH-7455).

## Knobs

Six settings rows, seeded by
`worker/jobs/schema.d/202611031509-bh-7941-e2e-ratchet-knobs.sql`:
`review.e2e_ratchet` (1), `review.e2e_baseline_runs` (50),
`review.e2e_baseline_jobs` (2), `review.e2e_baseline_ids` (30),
`review.e2e_baseline_timeout_s` (15), `review.e2e_baseline_calls` (6).
`review.e2e_ratchet=0` turns off the section read and the demotion.

## Third fix round

The lead review of 56171ef0 found that the `evidence` branch demoted a
weakened test with an ask for more runs on top ("ends in || true; need 3
full runs"). The `evidence` branch now cuts the ask out of the text and
reads the `weakened-test` row of `catalog/review-always-block.tsv` on the
rest. If it matches, the line stands. The `e2e-keep` row gains fixme,
`test.fail(`, retries, continue-on-error, allow-failure, quarantine,
comment out, disable, xfail and `expect.soft`. A bare ask with a
`weakened-test` tag (case C4) still demotes. Cases W1-W9 in
`tests/review-level-e2e-ratchet.bh-7941-test.sh` pin this.

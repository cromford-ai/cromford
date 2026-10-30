# Every retention rule lives in retention.d/ (BH-8407, BH-8398.1)

Doc: worker/jobs/README.md

## Why

BH-8406 (BH-8398.0) added the `retention.d/` fragment dir and moved one rule.
The other 47 rules stayed in the `INLINE_RULES` literal of
`worker/jobs/src/routes/retention.js`, so that file was still a shared append
point.

## What changed

- The 47 rules of `INLINE_RULES` moved, byte for byte with the comment block
  above each rule, into 28 new fragments, one per ticket:
  `worker/jobs/src/routes/retention.d/bh-<n>-<name>.js`. With
  `bh-7598-web-task-human-step.js` and `bh-7972-prompt-versions.js` there are
  30 fragments and 49 rules.
- `retention.js` holds no rule. It exports `RULES = FRAGMENT_RULES` from
  `#retention-rules` (the loader and the render already run `checkRules`). It
  keeps `runRule`, `intSetting` and the route.
- `COST_ARCHIVE_FLOOR_DAYS` (60) is defined in
  `retention.d/bh-6774-cost-rows.js`. `retention.js` re-exports it, so no
  caller changes an import.
- Rule order is now the fragment order: the numeric ticket, then the name.
  Each rule reads and deletes only its own table, so the order has no
  cross-rule effect. `stage_events.closed` (6750) still runs before
  `stage_events_daily.archive` (7109).
- `worker/jobs/test/archive-readers.bh-6779.test.js` excludes
  `src/routes/retention.d/*.js` as well as `retention.js` from the reader
  inventory.

## Where a new rule goes

Add a new file in `retention.d/`, keyed by your ticket. A fragment imports
only from `../../lib/`, never from `retention.js`.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/retention-moves.bh-8407-test.sh`
`HARNESS_TEST_SANDBOX=1 bash tests/retention-split.bh-8398-test.sh`

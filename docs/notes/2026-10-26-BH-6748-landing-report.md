# The landing report and the flip procedure (BH-6748)

Doc: DORA, OPERATING

Wave 5 of 5 of #6541. The optimistic-landing flip now has its evidence.

## What changed

- The daily DORA digest has a `landing` block (`fleet.landing`), one line
  per project with landing activity: merges by path (direct / queued), reverts
  of direct merges, CI job-minutes per merge, open->merge p50/p90 by path, and
  the shadow agreement rate. A window with no direct merge prints the count 0
  and `n/a` for every figure derived from direct merges. A refused GitHub
  pulls read prints `direct reverted n/a of N`, and a refused pulls read or a
  missing attempts file prints `shadow agree n/a of N`, never 0 or 100%.
- New operator CLI `bin/landing-replay.sh`: the last 7 days (settings row
  `landing.replay.days`) of `landing_decisions` and the merge ledger. It prints
  what optimistic mode would have landed directly, how many of those PRs were
  reverted or ejected later, and the CI minutes saved. The `LANDING_REPLAY`
  lines are the last lines, for a paste on #6541.
- Both read through one fetcher, `bin/lib/landing-sources.sh` `ls_fetch`, and
  count with `bin/dora_landing.py`.
- `GET /api/landing-decisions` takes an optional `before_id` cursor. No
  `before_id` answers the same rows as before.
- Four knob rows: `landing.report.decision_pages` (10),
  `landing.report.ledger_pages` (5), `landing.report.gh_pages` (3),
  `landing.replay.days` (7).
- `docs/OPERATING.md` has the flip procedure, written with `<project>`: that
  doc names no project (tests/operating-doc.bh-5289-test.sh O5). For this
  fleet the order is: cromford first
  (`lane.merge-conductor.cromford.mc_landing_mode`), watch 24 h, then
  cromford (`lane.merge-conductor.cromford.mc_landing_mode`), then the client
  repos one per day, each with its own row. Rollback sets the same row back to
  `queue`. The flip ticket is #6541.

## What did not change

- No mode row is set. The flip is an operator step on #6541.
- No conductor code, no new alert, no new cron line.

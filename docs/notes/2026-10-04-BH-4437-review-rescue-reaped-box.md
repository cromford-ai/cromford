# Review rescue finds REVIEW_BLOCKED builds whose pool box was reaped (BH-4437)

Doc: verification-map

## What changed

- `bin/review-rescue.sh` has a new pass, `ledger_materialize`. It runs after
  `verdict_backfill` and before the candidate walk.
- For each fleet project it reads the builds-of-record ledger
  (`bor_list`, `bin/lib/builds-of-record.sh`). A `result` row qualifies when
  all of these hold:
  - line 1 starts `REVIEW_BLOCKED`;
  - `build_dir` is a plain name (`^[A-Za-z0-9][A-Za-z0-9._-]*$`) and the job
    id is set;
  - the hub has no dir for it (`bor_local_dir`: exact, `pool-`, `fly-`);
  - no `builds/*/RESULT` already carries its `JOB_ID:` (a staged `-remote`
    copy);
  - its age is between 90 minutes and `RESCUE_LEDGER_LOOKBACK_H` hours;
  - `job_verdict_state` says the job has no verdict artifact (rc 2).
- A qualifying row becomes `builds/pool-<build_dir>/`. It holds `RESULT`
  (the ledger's line 1, `SOURCE:`, `JOB_ID:`, `BUILT_AS:`, `MATERIALIZED:`,
  mtime set to the ledger's `updated_at`), `plan.md` from the job's `plan_md`
  transcript when the ledger has one, `.rescue-materialized` and
  `.stale-flagged`. The dir is built aside and moved into place in one `mv`.
- The existing walk picks the dir up in the same tick. `rescue_one` is
  unchanged for it: it finds the open PR or the pushed branch, takes a
  worktree on the pushed head and re-runs the review there.
- When a materialized record has no open PR and no pushed branch, `rescue_one`
  appends `RESCUE_OUTCOME: no-branch …` to RESULT, writes one ALERTS line,
  then stamps `.review-rescued`. Line 1 stays `REVIEW_BLOCKED`, so
  `bin/blocked-resolver.sh` picks it up for a fresh rebuild. A hub-local dir
  with no branch keeps the old behaviour (retired, no ALERTS line).
- An outage on the ledger feed or the verdict read writes nothing; the next
  tick retries. At most `RESCUE_PER_TICK` records are materialized per tick,
  oldest first, and the pass logs a `capped` line when it stops early.

## Why

project-3 TK-209 (2026-10-03, PR #397 opened by hand) and TK-251 (2026-10-04,
alert 19465): the review died on a pool box, the box was reaped before the
result was relayed, and review-rescue only ever looked at the hub's
`builds/`. The only thing that noticed was `bin/stale-owed-tickets.sh`'s
ORPHANED BUILD alert, which asks for the review to be re-run by hand.

## Identity

The record is named `pool-<build_dir>`, the name a relayed copy of that build
would have had. `bor_local_dir`, `bor_union`, `bin/blocked-resolver.sh` and
`bin/stale-owed-tickets.sh` all map the ledger row to it without any change.
Once the dir exists the resolver takes its local-dir branch and waits for
`.review-rescued` (or its 6 h floor), so it cannot rebuild the ticket in
parallel with the rescue.

That only holds for a row the pass reaches before the resolver does. From hour
6 the resolver's ledger-only branch acts on the same row and records it only in
the ticket's state file (`state/blocked-resolver/<p>/<p>-<KEY>.json`), and once
a dir exists the resolver no longer reads that file for it. So the pass also
skips a row when:

- the resolver state has the build in `rebuild_seen` (plain, `pool-`, `fly-`)
  or a non-hold ladder attempt at or after the row (the resolver's own NOT
  RE-OFFERED test; an unreadable file fails closed), or
- the ledger holds a newer `result` row for the same ticket under another
  build_dir. `rescue_one` finds the PR by ticket key, so it would review the
  newer build's PR a second time.

Both matter for the 6 h to 168 h backlog the first ticks after deploy see, and
for any row the cap, the lane switch or a worker outage held past hour 6.

## Knob

`RESCUE_LEDGER_LOOKBACK_H` (lane `review-rescue`, int, default 168, 1..720
hours). It bounds how far back the pass reads; it prunes nothing.

## Verify

`bash tests/review-rescue-reaped-box.bh-4437-test.sh`. On the hub after
deploy: `grep -E 'materialized pool-|RESCUE_OUTCOME' /root/harness/logs/review-rescue.log`.

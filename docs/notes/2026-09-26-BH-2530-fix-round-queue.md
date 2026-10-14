# The hub queues fix rounds as rows and adopts their results (BH-2674, BH-2530.3)

Doc: MERGE-CONDUCTOR, DB-COORDINATION-SPEC

## What changed

This is the hub half of #2530. `bin/blocked-resolver.sh` no longer ssh's to the
box that owns a project to run a fix round there.

- **`br_fix_remote` enqueues.** It writes one `fix_round_jobs` row through
  `bin/lib/fix-round-queue.sh` (sourced beside `comment-mark.sh`, guarded the
  same way). The row carries the six `--fix-here` args and the hub's record as
  `record_in`, and is addressed to the owning box (`box-for.sh`). The box's
  `bin/fix-round-claim.sh` (BH-2672) claims it and runs `--fix-here` there.
  - A written row is one `resolver_rung` event, `rung 2 fix-round queued for <box>`.
  - A duplicate answer (a round already open for the park) is one log line and
    no event.
  - An outage, a 404, a 413 or a missing client is `fix round NOT queued — jobs DB
    unreachable, re-offered next tick`. Nothing is spent.
  - The hub keeps no pid row, temp file or lock for a remote round, so
    `state/blocked-resolver/rounds/` stays empty on the hub and a hub restart
    loses nothing about the round.
- **An in-flight gate in `br_one`**, right after the ABANDONED return, on a box
  that may not build here (`hub_box_builds_here` false). It reads the park's row
  with `fix_round_get`:
  - queued or claimed: `fix round in flight on <box> (<status> since <updated_at>)`,
    rc 3 (not a rung);
  - done: `br_fix_adopt`;
  - none (an adopted row is none): the ladder as before;
  - unreadable: `fix-round queue unreadable, park held this tick`, rc 3.
  - A row still `queued` after `BR_FIX_LANE_TIMEOUT` pages once through
    `lane-alert.sh --id fix-round-unclaimed-<project>-<cap-key>`. An
    `enqueued_at` that does not parse is logged and never read as age 0.
  - A row still `claimed` after `BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN`
    (by `updated_at`) pages once through `lane-alert.sh --id
    fix-round-stale-claim-<project>-<cap-key>` (review F1 on #2872). The claim
    route re-offers a stale claim only to the box holding it, so a box that
    died or was replaced mid-round would otherwise hold the park forever with
    no page. An `updated_at` that does not parse is logged, never a page.
  - `bin/lib/fix-round-queue.sh` missing on the hub is said every tick and
    pages once per project as `fix-round-queue-missing-<project>`: with the
    hop gone it is the only fix-round path.
- **`br_fix_adopt`** takes a done row's result once, in this order:
  1. `br_save` of `record_out`, only when it is this project's record and has
     more attempts than the hub's;
  2. the `fix_round_adopt` CAS (rc 9: another tick won it; rc 1: retried next
     tick, and neither takes a rung);
  3. the rung the box answered: done, box-paused, setup-blocked, terminal or
     rebuild-fresh, as the hop read them.
  The old catch-all "gave no FIX_RESULT" arm is gone. The claimer finishes a row
  only with a result the route's RESULT_RE accepts. Anything else is logged
  after the adopt and takes no rung.
- **`br_rounds_running` counts the fleet's remote rounds.** It is the live local
  pid rows plus `BR_REMOTE_OPEN`. `br_remote_open_prime` sets `BR_REMOTE_OPEN`
  from `fix_round_open_count` once per tick, before the drain. An unreadable
  count is 0 and says `open fix rounds unreadable — slot cap fails open this
  tick`.
- **`br_enqueue_fresh` no longer ssh's to remove the blocked stamp** on a box
  project. The `cleared` `commented` row is the re-offer. A row the DB did not
  take sets `BR_ENQUEUE_WHY="the jobs DB did not take the cleared row for <KEY>"`
  and returns 1 into the existing re-offer/alert path. The same-host arm lost
  its extra `rm -f`, because `cm_clear` removes the glob's local files whether
  or not the DB answers.
- `SSH_CMD` is gone from the resolver. The `BR_FIX_HOP_MARGIN` catalog row
  stays, with the same env, default and bounds. `bin/fix-round-claim.sh` reads
  it for its stale-claim cutoff, and the resolver reads it only for the
  stale-claim page above; its note says both.
- `--fix-here` is unchanged byte for byte. Only its header comment now names
  the claimer as the caller.

## Where the BH-2038 re-read went

The hub used to follow up a hop that came back with no usable record by doing
one bounded ssh read of the box's record. That behaviour now lives on the box,
in `bin/fix-round-claim.sh` step 2 (the re-offer guard). A re-offered row whose
box already holds more attempts than the row's `record_in` is finished from
that record, and nothing is bought twice. `tests/fix-round-claim.bh-2530-test.sh`
pins it.

## Tests

- `tests/fix-round-hub-restart.bh-2530-test.sh` covers the restart walk
  (queue, restart, in flight, box finish, adopt once) and the negatives:
  another cap key's row, an adopted row, a stale claim, a foreign record,
  box-paused, the worker down, a refused write, a refused or 409 adopt, the
  slot cap and the unclaimed page. Its fake worker is
  `tests/lib/fake-fix-round-worker.bh-2530.py`, invoked as `curl`.
- `tests/marker-rm-gone.resolver.bh-2530-test.sh` covers the re-offer with
  the worker up and down, and with 0 ssh calls in both.
- `tests/blocked-resolver.bh-594-test.sh` cases 6-7 now pin the queued row and
  the NOT-queued outage in place of the hop.
- `tests/blocked-resolver.bh-2038-test.sh` keeps cases 1-5, the box-side
  pause flags. Cases 6-12 pinned the hop bound and the hub's ssh re-read, and
  neither exists any more, so they were deleted. Box-paused read as nothing
  spent is pinned by the hub-restart suite's N5, and the re-read by the
  claimer suite.
- `tests/blocked-resolver-record-rows.bh-2317-test.sh` A10r now asserts no
  ssh and the `BR_ENQUEUE_WHY` line when the DB is down.
- Four suites reached the box re-offer with no ledger client, so they only
  ever passed through the ssh fallback. Each now gets `comment-mark.sh` and a
  recording `job_ledger_put`, and asserts the `commented … cleared` write in
  place of the ssh call:
  - `tests/br-rebuild-test.sh` section 3;
  - `tests/resolver-hold-test.sh` case 9;
  - `tests/blocked-resolver.bh-948-test.sh` fixture B;
  - `tests/resolver-cron-hygiene-test.sh`. Here case B's lock probe moved from
    the ssh child to the `commented` ledger write, which is the rung's child now.
- `catalog/lanes.d/blocked-resolver.json` gives `BR_FIX_HOP_MARGIN` a
  `read_in` of `bin/fix-round-claim.sh`, its main reader (the resolver reads
  it again only for the stale-claim page).

# A PR the blocked-resolver closes unmerged moves its console build row to `superseded` or `abandoned`

Doc: MERGE-CONDUCTOR, EVENTS

## What changed

BH-389. The blocked-resolver closed project-5 #1237/#1239/#1242/#1220 without
merging them. The console rows still read `stage=pr_merged, merged=1`, and the
kanban counted them as shipped. The `merged=1` stamp came from
`bin/reconcile-prs.sh` classifying on `state=CLOSED`, and BH-866 already fixed
that (a closed-unmerged PR now goes out under the `closed` key). The resolver
had its own gap: when it closed a PR it only sent a `fleet_event`. Nothing
addressed the closed PR's build row, and nothing named the rebuild that
replaced it.

- **`br_row_closed`** (`bin/blocked-resolver.sh`) sends one `kind:"build"` beat
  after a close that `br_close_pr` verified:

  | where | stage | detail |
  |---|---|---|
  | `br_rebuild_settle` rc 0, reached from both the fresh rung and the enqueue retry | `superseded` | `closed unmerged by blocked-resolver (<reason>); superseded by rebuild <job id> — <label>` |
  | `br_hold_abandon` (the ticket says ABANDON) | `abandoned` | `closed unmerged: <ref> says ABANDON` |
  | `br_abandon` (the ladder is exhausted) | `abandoned` | `closed unmerged: resolver ladder exhausted — <why>` |

  `merged` is always `false`. The row is addressed by run-build's own
  `bkey` (`build:<project>:<key>:<record basename>`) when there is a build
  record, and by `pr_url` either way. The beat carries no `tier`/`verdict`, so
  an earlier review stays on the row.
- **No beat** in observe mode, on a close GitHub refused, on the duplicate-race
  answer, or on an enqueue that failed. A failed enqueue has no successor to
  link yet, so the row keeps its pre-close stage until the retry lands and
  sends `superseded`.
- **No beat for a row from `br_from_rebuilds`** either (`rebuild-build-dead`,
  `rebuild-decompose-failed`, `rebuild-plan-blocked`, `rebuild-review-blocked`).
  Those rows pair the rebuild's own record with `parked_url`, the old PR that
  rung 3 already closed and beat `superseded`. A beat there would hang the old
  PR on the rebuild's row and claim a close that did not happen. The old row
  keeps `superseded`, and the rebuild's row keeps its own dead stage.
  `rebuild-enqueue-failed` still beats, because it carries the old PR's own
  record (`parked_rec`).
- **console-ui** treats `superseded` and `abandoned` as dead and never done
  (`src/lib/stages.js` `DEAD_STAGES`, so `buildLane` answers `dead`). The
  cockpit counts them as terminal (`functions/api/cockpit/[[path]].js`
  `TERMINAL_STAGES`), which takes them out of "building now". They were never
  in NEEDS and are not added to it.

Tests: `tests/blocked-resolver-closed-row.bh-389-test.sh`,
`console-ui/tests/stages.bh-389.test.js`, `console-ui/tests/cockpit-fn.bh-389.test.js`.

## Still owed, in the cromford-console repo

This box cannot read that repo, so these steps are not verified here:

- The beat upsert has to accept the free-text `superseded`/`abandoned` stages,
  and a `merged:false` build beat has to be allowed to clear an existing
  `merged=1` when GitHub `mergedAt` is null. Until it does, rows already
  stamped `merged=1` stay wrong.
- The reconcile route has to learn reconcile-prs' `closed` key
  (example-org/cromford-console#36).
- The four project-5 rows (#1237, #1239, #1242, #1220) need correcting once.

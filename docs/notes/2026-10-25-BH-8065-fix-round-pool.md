# A blocked-resolver fix round runs on the Fly pool by placement row (BH-8065)

Doc: FLY-POOL

Slice 2 of #8027. Slice 1 (BH-8027) put lead reviews on the pool. This slice
does the same for the fix round that `bin/fix-round-claim.sh` runs on a project
box. On box-project-6-os-1 that round died with rc 137 (SIGKILL).

## The row

`lane_placement.blocked-resolver-fix.<project>` = `fly`, read with `lp_decide`
(`bin/lib/lane-placement.sh`). Only the project row counts: `LP_WHY` must be
`lane_placement.blocked-resolver-fix.<project>=fly`. The project must also be
pool-routed (`queue_routing_facts` = `pool|0`). Any other answer is the project
box, as before: no row, a lane row, the default row, `box:<name>`, a halted or
`fly1` routing, or a settings outage.

The seed `worker/jobs/schema.d/202610251804-bh-8065-blocked-resolver-fix-project-6-fly.sql`
sets the row for project-6-os with `INSERT OR IGNORE`.

KILL KNOB: set the row to `box`. The next claimed round runs on the project box.
No deploy is needed.

## The flow

1. The hub is not changed. It still queues a `fix_round_jobs` row for the box.
2. The box claims the row, as before. With the placement fly, `frc_run` does not
   run `--fix-here`. It puts ONE `build_queue` row (`bin/lib/fix-round-pool.sh`
   `frp_put`): key `FXR-<id>-<ck8>` (`<ck8>` = first 8 hex of sha256(cap_key)),
   target fly, ticket_id `<id>`, meta
   `{kind:"fixround", id, box, project, cap_key, attempt, by}`. The args and
   record_in stay in the fix row. The fix row stays claimed by the box.
3. `bin/lib/queue-row-job.sh` writes `fixround:{…}` to job.json. A `fixround`
   meta on another key, or an `FXR-` key with other meta, or a key that does not
   name the meta's id and cap_key, is closed failed with one alert.
4. `fly/builder-runner.sh` `run_fixround_job` runs
   `bin/fix-round-claim.sh --run-pool <id> <box> <project> <cap_key>`. That
   reads the row again and runs the round only when its id, status `claimed`
   and `claimed_by` all match. The finish names the claiming box. A failed
   warm-up runs `--run-pool … --blocked "warm-up failed"`: one setup-blocked
   finish.
5. `bin/fly-pool.sh` reaps the row: `FIX_ROUND_FINISHED` and
   `FIX_ROUND_SKIPPED` close it done, `FIX_ROUND_SETUP_FAILED` closes it failed.
   A dead machine, a `BUILD_DEFERRED` and a word/key mismatch close it failed,
   never requeued, with one alert.

## The re-offer guard across the placement (box side)

| pool row `FXR-<id>-<ck8>` | box action | word |
|---|---|---|
| none | put, attempt 0 | queued |
| queued or claimed | nothing | inflight |
| done or failed | finish the fix row `setup-blocked` ("the Fly pool already ran this round as <key> …"), no second round | ran |
| unreadable, other status, or the put fails | nothing; the row stays claimed and the stale re-offer comes back | deferred |

A local run is never the fallback after the placement said fly.

## RESULT words

| word | meaning | reap |
|---|---|---|
| `FIX_ROUND_FINISHED <result> finish=<ok\|409\|failed>` | the round ran, one finish was sent | done |
| `FIX_ROUND_SKIPPED <why>` | the row is not claimed by the box; nothing ran | done |
| `FIX_ROUND_SETUP_FAILED <why>` | the lib is missing, the round did not start, or `--blocked` | failed |

`RESULT_PREFIX_RE` (`bin/result-prefix-ok.sh`) gains `FIX_ROUND_`. The pool
gates that know `LR-*` know `FXR-*-*` too: walk order, spawn gates, spawn cap,
tick budget, orphan rows, stall, ticket ownership, the docker key check and the
hotfix-only admit.

## Known limits

- A dead machine is answered by the box's stale re-offer
  (BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN, 95 min at defaults).
- A finish that fails on the machine loses that round's record. The re-offer
  then finishes the row setup-blocked, not done.
- Post-deploy probe (not run by the build): `grep 'FXR-' logs/fix-round-claim.log`
  on box-project-6-os-1 shows `queued on the Fly pool`; the hub fly-pool log shows
  `pool fix round reaped`.

Test: `tests/fix-round-fly-placement.bh-8065-test.sh`.

# BH-10057 slice C0: the resolver ladder (2026-11-25)

## What changed

1. A fix round that BH-9404 retries after a timeout (agent rc 124) runs with a
   larger agent budget. The budget is `BR_FIX_AGENT_TIMEOUT` ×
   `BR_FIX_TIMEOUT_RETRY_PCT` / 100. The default is 150 %, so 3600 s becomes 5400 s.
   The percent is clamped to 110..400, so the retry is always larger.
   - `bin/lib/fix-retry-budget.sh`: pure functions `frb_pct`, `frb_retry_s`, `frb_agent_max`.
   - `bin/blocked-resolver.d/bh-10057-timeout-budget.sh`: `brtb_agent_timeout` reads
     the BH-9404 mark `.timeout_retry` of the record. A round whose head carries a
     mark gets the retry budget. Every other round gets `BR_FIX_AGENT_TIMEOUT`.
     The round that gets the retry budget adds its head to `.timeout_retry_ran`.
     So each mark buys one larger round, and a later round on the same head
     gets `BR_FIX_AGENT_TIMEOUT` again.
   - `br_fix_round` calls `brtr_take` before the rounds-remaining exit, not
     after it. A timeout on round 1 of a cap-2 class is refunded and retried
     with the larger budget. Before, only a timeout on the last round was.
     The call sits before `brlad_round_failed` (BH-9437 pins that hook on the
     line right before the exit; it declines rc 124). A taken retry copies the
     round's verify output to `<ck>.fix-verify.prev.txt`, as that hook does, so
     the next round still gets the previous-verify brief.
   - `bin/blocked-resolver.sh` `br_fix_round`: one line before the agent call.
     Both the outer `timeout` and `agent-call.sh` get the answer.
2. The round bound admits the retry. When `BR_FIX_TIMEOUT_RETRIES` > 0, the
   agent term of `br_fix_bound` (`bin/lib/br/cap.sh`) and of the runner's
   round bound `FRC_T` (`frc_bound`, `bin/fix-round-claim.sh`) is the retry
   budget: 5400 + 2700 + 300 = 8400 s. Before: 6600 s. The pages
   `fix-round-unclaimed-*` and `fix-round-stale-claim-*` fire at 8400 s, not
   6600 s. The claim's stale cutoff stays A + V + M (`stale_min` 110): the
   route re-offers a stale claim to the same box only, and a re-offer of a live
   retry runs nothing (the round holds `locks/fix-round-<p>-<ck>.lock`; on the
   Fly pool the pool key is already queued or claimed). So a dead claim is
   re-offered as soon as before (BH-10115 F4).
3. Every ladder class buys at least 2 fix rounds. The registry default of
   `BR_MAX_FIXROUNDS` is 2 (was 1). The code fallback 1 answers only when the
   lane registry does not load. The small shape (`BR_CONFLICT_FIX_ROUNDS` 2) and
   the review park (`review.fix_rounds_max` 2) already had 2.

## Prod readings

On 2026-11-25 03:39Z prod had no `lane.blocked-resolver.BR_MAX_FIXROUNDS` row and
no `lane.blocked-resolver.BR_FIX_TIMEOUT_RETRY_PCT` row, so the registry defaults
are the live values after deploy.

## Not changed on purpose

- `queue-dequeued` keeps 1 round per claim (BH-3728).
- `review.mode` cowboy/off keeps cap 0 (BH-7123).
- `stale-replan` keeps its one rung, the re-plan (BH-3935).

## Deferred to later slices of #10057 (need #9554)

`plan_stale` requeue, `plan_blocked` defaults, orphaned build retries,
`ABANDONED` release and re-plan, parked queue rows, the un-ingested results
deadline.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/fixround-timeout-budget.bh-10057-test.sh`

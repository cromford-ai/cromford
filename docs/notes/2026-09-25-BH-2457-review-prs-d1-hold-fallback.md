# review-prs: the D1 hold has a time limit, then subscription runners only

Doc: REVIEW-PRS, COST

BH-2315 made review-prs hold (buy nothing) while the D1 verdict ledger could not be read. The hold
had no end. BH-2457 adds one, and it closes a gap in how a box decides it has a worker at all.

- **The hold has a clock.** The first held tick of an outage writes its epoch to
  `state/<project>.review-d1-hold`. It is a local file because D1 is the thing that's down. The clock
  is removed as soon as D1 gives a real answer (a verdict, or "no row"), or when the box has no worker
  (`JOBS_URL` empty). Every held tick touches the file, so a clock that no held tick has touched for
  over an hour counts as an outage that ended while no PR asked D1. The next outage starts fresh.
  A missing or unparseable clock starts now, and a future one reads as "not yet". A lost file can
  only mean holding longer, never paying sooner.
- **After N hours, subscription runners only.** The knob is `REVIEW_D1_HOLD_MAX_H`
  (`lane.review-prs.review_d1_hold_max_h`, default 6, 0 = hold until D1 answers, a value that is not
  a 0-999 hour count is read as 6 and logged). Once one outage has held that long, the head is bought on the runners
  `bin/billing-mode.sh` answers `subscription` for on this box, checked in the order claude, codex,
  grok, gemini, and intersected with a lane-level `AGENT_CALL_RUNNERS`. `metered` and `unknown`
  are never in the list. The call also pins `CALL_GUARD_FAIL_CLOSED_METERED=1`, so K3 keeps
  refusing metered spend even where an operator set it to 0. If no runner qualifies, the lane
  keeps holding and logs "no subscription runner on this box".
- **One alert per outage.** When the fallback starts, `state/<project>.review-d1-hold.fallback` is
  written first. Then one ALERTS line and one `beat.sh` fleet_alert go out, with akey
  `review-d1-fallback:<project>:<held-since-epoch>`. Each PR bought this way gets one
  `fallback: subscription-only (<list>)` line in `logs/pr-reviews.log`.
- **`jobs_configured` judges on `JOBS_URL` alone** (`bin/lib/jobs/req.sh`). An empty `JOBS_URL` is
  the only "no worker here on purpose" answer (BH-1957). An unset one defaults to the fleet worker,
  so a box that lost `HARNESS_SECRET` now holds instead of paying.
- **BLOCK replay.** A comment at the replay records that pipeline-built PRs (the build job's
  default BLOCK) are skipped at the loop's top and never replayed there.

Verified by `tests/review-prs-d1-hold.bh-2457-test.sh` (H1-H8, the real `bin/review-prs.sh` and the
real `bin/lib/jobs/req.sh`).

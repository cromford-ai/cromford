# Graph-engineering wave 2 (2026-08-23) — surface reopens, auto-resume dead builds, decision log

Prior wave (2026-08-18) already landed: reopen-metrics.sh (measure-only), RESUME_BUILD
checkpoints in run-build.sh (nothing invokes them), refuter lens. This wave closes the
three gaps the operator picked from the graph-engineering video review:

## 1. Goodhart counter-metric surfaced next to throughput
- [ ] cost-rollup.sh: read state/reopen-rate.json into summary.json per project
      (`reopens_14d`), and append reopens to the nightly cost-per-PR Telegram beat line.
- VALIDATE: python fixture run — summary includes reopens_14d; beat line renders with reopens.
- Fail-open: missing/broken reopen-rate.json → field null, beat line unchanged.

## 2. Auto-resume died-mid-flight builds (the wiring for RESUME_BUILD)
- [ ] run-build.sh: write $BUILD/job.json {project,ticket_id,key} at dir creation
      (resumer needs the ticket id; dirs predating this are skipped — converges).
- [ ] NEW bin/resume-dead-builds.sh (cron */30 all boxes):
      dead = builds/<dir> with job.json, NO RESULT, newest file >20 min old,
      build-key lock NOT held (flock probe — a live pipeline holds it), project
      not fly-flagged, not pool-*/COMMENTED. One resume per tick (oldest first),
      slots pre-checked via count-builds.sh. Attempt cap 2 (resume-attempts file);
      cap exhausted → RESULT "BUILD_DEAD ..." + ALERTS line (sweep posts it honestly).
      A resume that exits BUILD_DEFERRED gets its RESULT cleared + attempt refunded
      (deferral is weather, not death). Kill switch flags/resume-disabled. --dry-run.
- [ ] tests/resume-dead-builds-test.sh (red first): candidate selection, held-lock skip,
      RESULT skip, no-job.json skip, cap→BUILD_DEAD, deferred-resume RESULT cleared,
      launch via RUN_BUILD stub records env+args.
- [ ] cron: add to all 8 box cron files.
- Distinct from review-rescue.sh (owns died-mid-REVIEW builds that HAVE a RESULT).

## 3. Decision log (why triage routed what it routed)
- [ ] NEW bin/decision-log.sh <project> <gate> <scope> <outfile>: extract ^DECISION:
      lines (cap 40, 300 chars each) from the triage session's final output, append
      stamped+annotated to logs/decisions.log. Fail-open, exit 0 always.
- [ ] run-triage.sh: AGENT_SYSTEM_APPEND gains the DECISION line contract; call
      decision-log.sh after agent-call.
- [ ] tests/decision-log-test.sh (red first): extraction, cap, no-block no-op, malformed pass-through.

## Verify
- [ ] bash -n on every touched script; both new test suites green; gate-diff-test.sh still green.
- [ ] commit + push; boxes pick up via harness-sync/update-runners (cron applies 05:17Z).

## Review
Adversarial review (code-reviewer agent) on the staged diff: VERDICT BLOCK with 2 blocking
+ 3 important findings — ALL fixed before merge:
- B1 COMMENTED lifecycle: a swept deferral's COMMENTED marker survived resume, so the real
  verdict never reached the board. Fixed at the choke point (run-build.sh resume block now
  rm's RESULT+COMMENTED) plus belt-and-braces in the resumer (refund + pre-launch).
- B2 refund defeated the cap on permanent deferrals (deleted branch, wedged worktree →
  infinite hourly relaunch). Added never-refunded resume-total counter, cap 6 → BUILD_DEAD.
- I1 nohup'd pipeline inherited the resumer's flock fd 9 → one resume per BUILD not per
  tick. Fixed with 9>&- on launch.
- I2 no prompt knew the BUILD_DEAD verdict → added to all 9 sweep SOPs (honest board
  comment + ALERTS + COMMENTED).
- I3 twin-PR risk resuming a shipped branch → gh PR-state guard before relaunch
  (MERGED→PR_MERGED RESULT, OPEN→PR_CREATED RESULT, gh weather→conservative skip).
- NITs: empty ticket_id field-shift guard, cron PATH prepend. Accepted: multibyte cut in
  decision-log (log-only), lock-probe micro-window (self-heals via triage retry).
Final: resume suite 22/22, decision-log 5/5, gate-diff green, bash -n clean.

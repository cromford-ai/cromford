# A running pool build yields at its next write point under HOLD (BH-6091)

Doc: RUN-BUILD-GRAPH

## What changed

- `bin/lib/hold.sh`: a person's comment that opens with capital `HOLD` and then
  `:` or a dash (`HOLD_LEAD_RE`) is a hold, whatever follows. `decide` asks it
  right after the lead-lift arm and before the lift vocabulary. The order is
  now: needs-human, human-fix, lead-lift, lead-HOLD, lift, abandon, done, hold.
  `bin/launch-fastpath.sh` asks the same rule in its python copy.
- `RB_PUSH [-u] [<stage>]` (`bin/lib/rb/gates.sh`) takes a stage name. When
  `hold_push` answers held (rc 3), `RB_HOLD_YIELD` writes
  `HOLD_YIELD <KEY> at <stage>` to `pipeline.log` and the RESULT
  `BUILD_DEFERRED HOLD_YIELD <KEY> at <stage> — …`, and exits 3. The commits
  stay in the build worktree. In a subshell (the background E2E lane) it
  returns 3 and writes no RESULT. An unreadable hold (rc 4) is unchanged: no
  push, and the next write point reads the hold again.
- `RB_HOLD_GATE <stage>` reads the same verdict (`hold_push_verdict`) for a
  write that is not a push. The `pr-open hold gate` block in
  `bin/lib/rb/pr.sh` calls it right before the PR create. Unreadable there
  writes `BUILD_DEFERRED hold unreadable at pr-open` and exits 3.
- The `pr-body hold gate` block in `bin/lib/rb/result.sh` skips the evidence
  `gh pr edit` when the ticket is held or the hold is unreadable. It logs
  `HOLD_YIELD <KEY> at pr-body-edit` and keeps the `PR_CREATED` RESULT.
- Push stages: `execute` and every fix-round push name their `PUSH_BRANCH`
  label, then `e2e`, `pr-push` and `qa-fix`.

## Why

On #5962 (2026-10-11/12) the pool pushed twice and opened PR #6089 while the
newest HOLD/RESUME comment was HOLD. Every pool push already re-read the hold
(BH-2504). Both HOLD comments contained a capital RESUME, and the lift-anywhere
arm read each one as a lift.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/pool-hold-yield.bh-6091-test.sh` and
`HARNESS_TEST_SANDBOX=1 bash tests/launch-fastpath-test.sh` (T1.4f).

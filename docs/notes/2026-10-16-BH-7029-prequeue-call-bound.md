# BH-7029: each prequeue call is named, timed and bounded

Ticket: example-org/cromford#7029 (Sentry CROMFORD-HARNESS-1C). The
merge conductor's `prequeue` step ran past `MC_STEP_TIMEOUT_S` (240 s) 6 times
on box-hub / project-5. The kill named only the step. No log line said
which call inside the step was slow.

## What changed

- `pq_call [-w] <name> <cmd> ...` (`bin/lib/mc-prequeue.d/call-bound.sh`) runs
  each call of `pq_gate` and of its resolver in the same shell. Each call
  writes one line to the lane log:
  `<slug>#<num> PREQUEUE_CALL call=<path> took=<s.s>s rc=<rc>`.
  The path of a call inside a call is `resolve/<name>`. The names are
  `main-tip`, `restamp` (write), `resolve`, `resolve/wf-probe`,
  `resolve/settle`, `resolve/compare`, `resolve/merge-test`, `resolve/adopt`,
  `resolve/impact-reuse`, `resolve/veto`, `resolve/dispatch` (write) and
  `status` (write).
- `pq_gate` runs its calls under one budget, the settings knob
  `MC_PREQUEUE_CALL_BUDGET_S` (default 150 s, 0 = off). The value used is
  never above 3/4 of `MC_STEP_TIMEOUT_S` and never past the worker deadline
  minus 15 s. When the budget passes:
  1. A READ in flight is killed. Only the direct children of the shell that
     runs the call, in its session, that started at or after the call are
     killed. A setsid child and a child from before the call are not touched.
  2. A WRITE in flight (a push, a dispatch, a commit status) runs to its end.
  3. No later call starts (`pq_call` returns 124 and logs `skipped=over-budget`).
  4. `pq_gate` answers `hold`. `PQ_WHY` names the call. One
     `<slug>#<num> PREQUEUE_CALL_TIMEOUT call=<path> budget=<b>s head=<h8>`
     line goes to the log. The row stays READY and the next tick asks again.
     There is no alert and no Sentry event.
  5. A verdict the resolver reached after the budget passed does not count.
  A budget under 1 s (the worker deadline is too near) holds at once with
  `call=none` and makes no call.
- Two guards in `bin/lib/mc-prequeue.d/dispatch.sh` stop a killed read from
  becoming a write. `pq_settle` holds when the budget passed, before the
  deadline rule, so a killed run read never records could-not-run or alerts.
  Nothing is dispatched past the budget.
- `mc_worker_bounded` (`bin/lib/fanin.sh`) gives the worker
  `MC_CALL_FILE=<mark>.call`, the call in flight. The step watchdog reads it
  before it writes the mark. When a call runs, the mark gets fields 8 and 9:
  the call path and its seconds. A kill with no call in flight (any other
  step) writes the same 7-field mark as before, and it reads as call `none`.
- `mc_fanin_outcome` puts ` | call: <path> (<n>s)` in the STEP_TIMEOUT line
  and alert, before ` | calls:`, and adds the tag `call`. With call `none` the
  line and the tags are as before. The Sentry extra always has `call` and
  `call_s`. WORKER_DEADLINE and STEP_HELD do not change.
- Three existing assertions change (TEST-CHANGE in the commit):
  `tests/prequeue-restamp.bh-6842-test.sh` P9 ("no line" now means no line
  other than PREQUEUE_CALL) and its M1 mutation anchor (the restamp call is
  now `rs=$(pq_call -w restamp pq_restamp ...`), and
  `tests/conductor-queue-on-prequeue.bh-6924-test.sh` Q1 (a PREQUEUE_CALL
  timing line is not an ask).

## What did not change

Verdict logic, dispatch rules, the cache format and `bin/merge-conductor.sh`.
`prequeue` is still not a holdable step.

## Owed after deploy

1. On box-hub, after 3 slow ticks, run
   `grep -E 'PREQUEUE_CALL(_TIMEOUT)? ' /root/harness/logs/merge-conductor.log | tail -50`
   and name the slowest call on the ticket.
2. Check Sentry CROMFORD-HARNESS-1C: 0 new `conductor-step-timeout` events with
   `step=prequeue` for project project-5 over 24 h.

Test: `tests/prequeue-call-bound.bh-7029-test.sh`.

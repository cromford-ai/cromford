# BH-8497: the triage snapshot reads every open ai-build issue; no-DECISION verdicts are retried

Doc: TRIAGE-STATE

## Cause

1. `bin/triage-gate.sh` `fetch_fingerprint` read one page of
   `issues?labels=ai-build&state=all&per_page=100`. That page held the 100
   newest issues. On project-6-os (131 open) it held 13 open ones, so 118 old
   open tickets were not in the fingerprint, and triage never saw them.
2. `bin/triage-state.py` `record` stamped a model-set ticket with no DECISION
   line `triaged`, reason `... no DECISION line, session rc 0`, and no timer at
   TTL 0. `due_at` rule e ("otherwise never") kept it off the model forever.

## Fix

1. `bin/lib/triage-board-pages.sh` `tbp_issue_pages` pages `state=open` to the
   first short page, up to `tbp_max_pages` (row
   `lib.triage-state.<project>.triage_state_board_max_pages`, fallback 20). The
   snapshot holds no closed issue (comment 6426367666): a closed blocker's
   state comes from the `refs.json` REST lookup. A full cap page writes one
   ALERTS line per project per UTC day. Any failed page fails the fetch.
2. The no-DECISION reason carries a counter, `(no-decision c/N)`, and a
   backoff stamp. `due_at` puts it back in the model set until `c` reaches N
   (row `lib.triage-state.<project>.triage_state_no_decision_retries`, fallback
   3). Then `(no-decision retries spent N/N)` is final, and
   `ts_after_session` writes one ALERTS line naming the keys.
3. A blocker off the fingerprint already moved its child's hash through
   `refs.json`. The new suite pins it.
4. `bin/orphan-reconcile.sh` `ORPHAN_THREAD_FETCH_MAX` is a settings row
   (`lib.orphan-reconcile.<project>.orphan_thread_fetch_max`, registry
   `catalog/lanes.d/_lib.orphan-reconcile.json`, fallback 200, was a literal
   40). Past it, a thread cursor
   (the `ledgers` row kind `orphan-thread-cursor`, key `<owner>/<repo> <mode>`) makes the next
   run read the cut threads first, and one ALERTS line per project per UTC day
   names the count.

## Effects

- The first tick after deploy sees a new issue set on every board over 100
  ai-build issues and wakes once. Each open page is a 304 when nothing moved.
  A ticket that closes leaves the snapshot, and that change wakes the tick.
- Rows with the bare no-DECISION reason (project-6-os: 19) go back to the model
  once on the first tick.
- Out of scope: the thread-read cap `TRIAGE_STATE_MAX_FETCH` (30) reads the
  newly visible threads over several ticks.

## Check

`grep 'triage-state enforce' logs/project-6-os.log | tail -1` says `131 open`
(or the repo's current open ai-build count). Suites:
`tests/triage-board-pages.bh-8497-test.sh`,
`tests/triage-state-no-decision.bh-8497-test.sh`.

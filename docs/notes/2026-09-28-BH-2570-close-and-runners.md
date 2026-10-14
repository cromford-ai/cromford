# Alert-triage closes re-verified rows and keeps grok off (BH-2544.1, BH-2570)

Doc: ALERTS-STATE-MACHINE

## What changed

This fills in the two stubs the BH-2568 contract left
(`docs/notes/2026-09-25-BH-2544-contract.md`) and reads the knob it registered.

- **Close.** A row the lane claimed from the D1 `alerts` table (its line carries
  `"dbrow":true`) is resolved through `alert_resolve` when a positive re-verify
  says its condition cleared:
  - `bin/triage-spool-retire.sh` appends the `alertid` of every retired
    NOISE-STALE dbrow line to `TRIAGE_RETIRE_IDS_OUT`, only after the archive
    holds the receipt. Summary line, archive and workfile are unchanged.
  - `triage_settled_ids` picks the dbrow ids of settlements whose reason is
    `resolved:`, `superseded:` or `verify:`.
  - `triage_close_ids` dedupes them, drops an id the worker's regex would
    refuse, and sends slices of at most 90. Each slice logs
    `CLOSED (no model call) reason=<step0|settle> resolved=<n> of <m>`, where n
    is the worker's count. A failed slice logs `close rc=<rc> for <m> id(s)` and
    is not retried: the row stays quarantined and the 900s lease re-offers it.
    With `ALERTS_DB` off nothing is sent and one `close skipped` line is logged.
  - Never closed: EXPIRED-AGE, EXPIRED-CONDSTATE, `stale-akey:`, and any line
    without `"dbrow":true`. The switch `triage-close-off` (row, then flag file)
    still skips both closes.
- **Runner allowlist.** `TRIAGE_RUNNERS` (settings row
  `lane.alert-triage.triage_runners`, seeded `claude,fireworks` by
  `worker/jobs/schema.sql` with INSERT OR IGNORE) goes to the strong call, the
  floor call and the cliff floor retry as a per-command `AGENT_CALL_RUNNERS`.
  The floor calls intersect it with `FLOOR_RUNNERS_ONLY`. If that leaves no
  runner, the family is re-spooled at its pre-tick stamp with one
  `no floor runner allowed` line and no call; on the cliff retry the retry is
  skipped and the family takes the existing cliff deferral. Empty row = no
  prefix = the old ladder. Why: the context meter cannot see grok requests
  (`docs/verification-map/responder-cliff-cap.md`), so grok could run this lane
  past its 200K price cliff.

## Operator

- `grep -E 'CLOSED \(no model call\)|close rc=|close skipped' logs/alert-triage.log`
- `bin/harness-ctl.sh set alert-triage TRIAGE_RUNNERS <list>` changes the
  allowlist (runner names only). `set` refuses an empty value, and a deleted
  row is re-seeded by the next deploy (INSERT OR IGNORE only skips a row that
  exists), so to let grok back on, name it in the list.
- Closes stop with the switch `triage-close-off`: its settings row
  (`switch.triage-close-off`), or `flags/triage-close-off` when there is none.
- Tests: `tests/alert-triage-close.bh-2544-test.sh`,
  `tests/alert-triage-runners.bh-2544-test.sh`.

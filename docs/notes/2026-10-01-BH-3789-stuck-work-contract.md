# stuck-work: the contract slice and a stub hub lane (BH-3789)

Doc: OPERATOR-SETUP

## What changed

This is slice 1 of BH-3781. It fixes the contract the other slices code to and
puts a stub lane on the hub.

- `catalog/lanes.d/stuck-work.json`: lane `stuck-work`, scope hub, `boxes:
  ["hub"]`, every 5 minutes, switch flag `lane-off-stuck-work`. Knobs:
  `STUCK_WORK_ENABLED` (int, default 1, 0 = off) and the test seam
  `STUCK_WORK_NOW` (`settable:false`, honoured only under
  `HARNESS_TEST_SANDBOX=1`).
- `catalog/switches.d/stuck-work-off.json` and `cron/lanes/723-stuck-work.cron`
  (`# @hub-lanes`, behind `hub-lease.sh check` like every hub lane).
- `bin/stuck-work.sh` logs one line per tick to `logs/stuck-work.log`: ` off`,
  ` disabled` or ` stub`. It reads nothing from GitHub and pages nobody.
- `bin/lib/stuck-work/classify.sh` fixes the 22-field FACTS line, the
  `stuck_work_snapshot`/`latest` ledger row and the `sw_state`, `sw_sla_s`,
  `sw_decide`, `sw_key`, `sw_page_text` signatures. All five are rc 1 stubs.
- `bin/lib/stuck-work/facts-pr.sh` (`swf_pr_facts`) and `facts-ticket.sh`
  (`swf_ticket_facts`) are rc 1 stubs with the rc 0 / 3 / 1 contract documented.
- `bin/lib/stuck-work/seen.sh` is real: `sw_first_seen <key>` writes
  `{"first_seen":<now>}` to ledger kind `stuck_work_seen` only when the row is
  absent (the ledger PUT is an upsert, so a re-write would reset the clock),
  and prints `?` when the ledger is down, the row does not parse, or the write
  fails.

## Deferred

`STUCK_WORK_FIXTURE` is not registered yet. Nothing in this slice reads it, and
`tests/lanes-registry-test.sh` refuses a knob nothing reads; the fact-reader
slice that reads it registers it. No settings seed is added to
`worker/jobs/schema.sql`: the registry default is the fallback.

Test: `HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-stub.bh-3781-test.sh`.

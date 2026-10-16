# Archie as Overlooker of the staff agents (BH-5562, wave 5 of #5556)

Doc: EVENTS, OPERATOR-SETUP

## What changed

A new hub lane, `archie-overlook` (`bin/archie-overlook.sh`, registry
`catalog/lanes.d/archie-overlook.json`, cron
`cron/lanes/729-archie-overlook.cron`, `8-58/15` behind `hub-lease.sh check`).
It makes no model call. The steps are in the script header. In short:

1. Tripwires. For each roster agent, the lane reads the acted files that
   `bin/staff.sh` wrote today (UTC, by file mtime). 25 actions of one class
   slug (`STAFF_OVERLOOK_FAMILY_MAX`) or 10 filings (`STAFF_OVERLOOK_FILE_MAX`)
   trip the agent. A trip writes `flags/staff-off-<agent>` with `flag_set`,
   makes one warn beat (`lane-alert.sh --id staff-trip-<agent>-<day>`) and
   puts ledger row `archie_overlook trip-<agent>-<day>` = `paused`. If a person
   clears the flag the same day, the ledger row stops a second pause that day.
2. Duplicate scan. Only after a new `filed` acted file (newer than
   `state/archie-overlook/dupscan.stamp`), the lane lists the open
   `staff:<agent>` issues. A `<!-- staff-fp:<fp> -->` marker on two or more
   open issues is one warn beat (`--id staff-dup-<fp12>`). Nothing is closed.
3. Weekly report. On Monday UTC (`STAFF_OVERLOOK_REPORT_DOW`), once per ISO
   week (ledger `weekly-<GGGG>-W<VV>`), one report goes through Archie's
   `archie_beat_gate`: one block per accountable owner, and per agent the
   filings, digests, precision and spend of the last 7 days.

A new soul fragment, `prompts/archie-soul.d/80-overlooker.md`, tells Archie
these duties and that staff agents never message the operator. No other fragment
changed. It opens no MAY, NEVER or REPORT list.

## Limits a reader must know

- Spend per agent reads cost rows with stage `staff.<agent>`. Today
  `bin/staff.sh` writes one stage, `staff-tick`, for every agent, so the
  report shows `spend $0.00` per agent and the real total on the
  `unattributed staff-tick spend` line. A follow-up that tags the agent in
  the cost row fills the per-agent number.
- Precision comes from GitHub until the BH-5563 outcome rows exist: a
  `staff:<agent>` issue closed in the last 7 days as `completed` agrees, as
  `not_planned` overrules. A list that fails prints `precision unreadable`.

## Operate

- Off: `ARCHIE_OVERLOOK_ENABLED=0`, `flags/lane-off-archie-overlook`, or
  `bin/harness-ctl.sh off archie-overlook`.
- Resume a paused agent: run `bin/jobs-client.sh flag-clear staff-off-<agent>
  "<reason>"`. The lane never clears it.
- Log: `logs/archie-overlook.log`. Reports: `state/archie-overlook/weekly-*.md`,
  deleted after 84 days by the weekly run.
- Test: `HARNESS_TEST_SANDBOX=1 bash tests/staff-overlooker.bh-5562-test.sh`.

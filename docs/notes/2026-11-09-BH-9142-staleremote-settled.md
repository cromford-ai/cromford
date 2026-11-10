# BH-9142 — staleremote does not page an old json whose PR exists

## Problem

project-6-os TK-832..TK-860 hub jsons (`state/remote-results/project-6-os/`),
dated 2026-10-16, paged "unconsumed >30m" every 2 hours for 3 weeks.
TK-860.json records `PR_CREATED https://github.com/example-org/project-6/pull/877`.
The record itself proves the PR exists.

Root cause: in the staleremote block of `bin/pipeline-health.sh`, the only rule
after the RELAYED skip was the 30-minute file age. The block asked the ledger
only when the build folder was gone. A json with a present folder and no
RELAYED paged on file presence and mtime alone. The jsons are older than
BH-8450, so they have no `rr-consumed` row either.

## Change

Two skip rules run before the folder and ledger branch. Neither reads the
ledger, the owning box or GitHub, so they spend no `STALEREMOTE_LEDGER_READS`
budget.

1. Retired: the retention rule (`bin/remote-results-retention.sh`) marked the
   key with the same json mtime in `state/remote-results-terminal/<p>.tsv`.
2. PR settled: `rr_json_pr_settled` (`bin/lib/remote-results-ledger.sh`) finds
   a result first line `PR_CREATED|PR_MERGED|PR_CLOSED <github pull url>` AND
   the json is older than `STALEREMOTE_PR_SETTLED_DAYS`.

A fresh PR json (younger than the window) still pages: its close-out is still
owed. Other terminal verbs (PLAN_BLOCKED and so on) still page.

New summary line, one per project per tick, only when a json was skipped:

    <ts> <p> staleremote: settled <n> (pr older than <d>d <a>, retired <r>; not paged)

The two existing staleremote lines do not change.

## Knob

`STALEREMOTE_PR_SETTLED_DAYS` (lane `pipeline-health`, default 7, 0 = off,
max 365; a non-number or a value over 365 falls back to 7). Row:
`catalog/lanes.d/pipeline-health.knobs.d/STALEREMOTE_PR_SETTLED_DAYS.json`.

## Operator step

The retention rule is still dry-run by default, so the retired skip only acts
after this step. Read the dry-run audit line in
`logs/remote-results-retention.log` first, then run:

    bin/harness-ctl.sh set pipeline-health REMOTE_RESULTS_RETENTION_APPLY 1

## Not in this change

This change moves or deletes no file under `state/remote-results/`. That path
is class `rows` (BH-4159), and BH-8364 C1 owns the removal of the file writers.

## Test

`tests/pipeline-health-staleremote-settled.bh-9142-test.sh`.

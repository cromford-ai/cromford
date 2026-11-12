# BH-9368: migration-gate reds, the green-CI park release, and the ledger under an apply lane

Ticket: example-org/cromford#9368 (label `hotfix`). Comments 6754703346 and
6776463970 add scope.

Doc: MERGE-CONDUCTOR, MERGIFY

## The incidents

- project-6 #3728 (bh-hub-2, 2026-11-09): the only red REQUIRED check was
  `gate` (`migration-ledger.yml`). It was red because the PR adds a
  before-merge `prisma/sql/*.sql` file that production did not hold. The
  conductor re-ran it, struck it and parked it `RED_TWICE`.
  `bin/blocked-resolver.sh` then spent its whole ladder on a red that no branch
  change can turn green. Five approved PRs sat like that until a person
  applied the SQL.
- project-6 #3700 / #3728: a `RED_TWICE` row stayed parked after its CI went
  green. The CI word came from the read memo, and the BH-8012 net reads one
  check-runs page of 100, which a project-6 head overflows.
- project-6 #3726 (alert 61683): the project has
  `mc_migration_hold.apply_lane` set, so the conductor held the PR
  `HELD_MIGRATION ... left to the mac-batch lane` with no probe at all.
  Production's `schema_migration` already held the file at the head checksum.

## What changed

1. **The ledger is asked also under an apply lane** (`bin/lib/migration-hold.sh`).
   `mmh_decide` asks `migrations/status` for a lane-set project. A ledger row
   matches by name AND by the sha256 of the PR's head file (`mmh_head_sums`,
   the contents API; the same sum `dlp_probe` and the migration lane compare).
   Every file at the head checksum = `applied` (READY). Anything else = `lane`,
   as before (no comment, no alert), with the ledger answer in the reason:
   `left to the <lane> lane, which applies migrations before it merges (ledger: <detail>)`.
   With no lane, a row at another checksum is `changed` (the file counts as
   missing). A row with no checksum is a name match, as before.
2. **`WAIT_MIGRATION`** (`bin/merge-conductor.d/bh-9368-migration-gate.sh`).
   When every failing required check of a head is in the settings row
   `mc.migration_gate_checks.<project>` (seed: project-6-os = `gate`), the row
   is `WAIT_MIGRATION` with the reason
   `migration-gate: <checks> red; PR adds <sql names>`. No rerun, no strike,
   no resolver hand-off. The arm sends one alert per (PR, head) with the apply
   step. With `mc.migration_apply_workflow.<project>` set (no seed row), it
   dispatches that workflow once per (PR, SQL fingerprint). When the ledger
   holds every SQL file at the head checksum, it re-runs the gate once per
   (PR, head) (`bin/merge-conductor.d/bh-9368-ledger-gate-rerun.sh`).
3. **A park whose CI is green again is released**
   (`bin/merge-conductor.d/bh-9368-park-ci-recheck.sh`). A `RED_TWICE`,
   `WAIT_MIGRATION` or `BLOCKED_HUMAN red-twice*` row on its parked head gets a
   fresh CI read at most once per `MC_STICKY_CI_RECHECK_SECS` (600 s) per
   (PR, head). Green, or green under `mcr_ci_override`, releases the park
   (`PARK_RELEASED_CI_GREEN`) and the row classifies on the normal path in the
   same tick.
4. **A report-only check is not red with no readable required set**
   (`bin/lib/mc-ci-advisory.sh`). With `.mergify.yml` unread or with no
   `check-success` name, a failed run whose every failed job name ends in
   ` (report only)` (`MC_CI_REPORT_ONLY_SUFFIX`) is advisory. A
   `continue-on-error: true` job does not fail its workflow run, so
   `mc_ci_state` already reads that run as green; the jobs API does not show
   the flag, so no code reads it.

## Operator step: the right `apply_lane` value for project-6-os

`mc_migration_hold.apply_lane.project-6-os` must be `migration`, not `mac-batch`.
`bin/migration-lane.sh` (`ml_enabled`, lines 87-91) runs only when the row is
`migration`, and `docs/notes/2026-10-28-BH-8704-migration-lane.md` step 3 sets it
to `migration`. With `mac-batch`, no harness lane applies the SQL. Since this
change, a lane-set project still reads `applied` from the ledger, so the PR is
not held once production holds the file. The row change is an operator step
(`PUT /api/settings`); this change does not write it.

## Knobs and rows

| Name | Where | Default | Meaning |
|---|---|---|---|
| `mc.migration_gate_checks.<project>` | settings row (seed `worker/jobs/schema.d/202611111514-bh-9368-migration-gate-seed.sql`) | project-6-os = `gate`; else no row | space-separated gate check names; empty = off |
| `mc.migration_apply_workflow.<project>` | settings row | no row | a workflow file name; no row = alert only, no dispatch |
| `MC_STICKY_CI_RECHECK_SECS` | knob file | 600 | park recheck window per (PR, head); 0 = off |
| `MC_CI_REPORT_ONLY_SUFFIX` | knob file | ` (report only)` | report-only job name suffix; empty = off |
| `MC_TTL_WAIT_MIGRATION` | knob file | 86400 | stuck TTL of a WAIT_MIGRATION row |
| `MC_BUDGET_WAIT_MIGRATION` | knob file | 86400 | age budget: one page a day on; -1 = never page by age |

Attempts kinds (the `$MC_ATTEMPTS` store): `parkcigreen <key> <head>`,
`ledgergaterun <key> <head>`, `miggate <key> <head>`,
`migdispatchhead <key> <head>`, `migdispatch <key> <fp12>`. The park recheck
throttle is `state/merge-conductor/park-ci-recheck/<id>.<head12>` (the epoch of
the last read), pruned at 7 days on each write. No new D1 table.

## Known limits

- The dispatch input shape is project-6's `migrate-branch.yml`: `ref=<base>`,
  `inputs[file]=<basename>`, `inputs[ref]=<PR branch>`, one dispatch per file.
  A project with another input shape needs a later knob.
- "Re-run the gate when the run is green" is read as "the ledger holds the
  file at the head checksum". The conductor does not track the dispatched run.
- Inside the 600 s window, a WAIT_MIGRATION row whose gate just turned green
  can show `WAIT_CI checks red once` from the read memo for up to one memo
  window (15 min) before it is READY. No rerun rung is spent on it: the gate
  run holds no failed required check any more.

## Drive

Read `logs/merge-conductor.log` on the hub:
`grep -E 'WAIT_MIGRATION|PARK_RELEASED_CI_GREEN|LEDGER_GATE_RERUN|applied in production' logs/merge-conductor.log`.

Tests: `tests/merge-conductor-migration-hold.bh-9368-test.sh`,
`tests/mc-migration-gate.bh-9368-test.sh`, `tests/mc-park-ci-recheck.bh-9368-test.sh`
(the shared whole-tick fixture is `tests/lib/mc-gate-tick.sh`).

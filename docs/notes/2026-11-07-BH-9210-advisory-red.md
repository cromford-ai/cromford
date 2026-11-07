# The conductor red rule counts only the checks Mergify requires (BH-9210)

Doc: MERGE-CONDUCTOR, watchdog-spec

## Why

Measured 2026-11-07. `mc_ci_state` answered `red` for any failed latest
workflow run on a head. example-org/project-6 has two report-only workflows,
`unit-clock` and `unit-shuffle`, and their `report` job failed on every run
since 2026-11-02. Mergify required only `ci` and `e2e-ratchet`, and both were
green. The conductor logged `FANIN example-org/project-6: enumerated 8 accounted 8
(WAIT_CI 2, RED_TWICE 6)` at 15:06Z, and the blocked-resolver spent fix rounds
on heads with no real failure. The BH-8012 net reads one check-runs page of
100. A project-6 head holds more check runs than that, so the net did not fire.

## What changed

- `mc_ci_state` (`bin/lib/mc/classify.sh`) gives each failed latest run to
  `mca_split` (`bin/lib/mc-ci-advisory.sh`). On a Mergify repo (not project-4)
  whose `.mergify.yml` queue_rules name at least one `check-success`, a failed
  run is advisory when its jobs
  (`actions/runs/<id>/jobs?filter=latest`, up to `MC_CI_JOBS_PAGES_MAX` pages)
  were read in full and every job named like a required check concluded
  `success`. An advisory run leaves the list before the reduction. Any other
  conclusion of a required job, a failed read, a page that does not parse, a
  run with more jobs than the page cap, or a run with no job keeps the run red.
- Each advisory head writes one line to
  `state/merge-conductor/ci-advisory-red.tsv` and one log line per workflow:
  `advisory-red: <workflow> on <slug> <sha8>: its failed run holds no failed
  required check (<required names>); not red`. Lines older than
  `MC_CI_ADVISORY_KEEP_D` days are pruned when a new line is written.
- `mc_red_rerun` and `mc_flake_rerun` re-run only the failed runs that hold a
  failed required check. When none is left, `mc_red_rerun` logs `no failed run
  on <h8> holds a failed required check — no rerun, no rung spent` and writes
  no `cirerun` mark.
- The RED_TWICE reasons end with `failing required checks: <names>` when this
  tick's CI read named them. A memo hit keeps the old text.
- `bin/fleet-status-push.sh` adds `ci_advisory_red`: `[{repo, heads}]`, the
  heads per repo in the ledger in the last 24 h.
- With no queue rules, provider not `mergify`, project-4, or
  `MC_CI_ADVISORY_RED=0`, every failed run is red, as before.

## Knobs

`MC_CI_ADVISORY_RED` (1), `MC_CI_JOBS_PAGES_MAX` (3), `MC_CI_ADVISORY_KEEP_D`
(7), one file each in `catalog/lanes.d/merge-conductor.knobs.d/`.

## Tests

`tests/mc-ci-advisory-red.bh-9210-test.sh`, `tests/fleet-status-ci-advisory.bh-9210-test.sh`.

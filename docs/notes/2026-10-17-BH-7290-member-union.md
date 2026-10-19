# BH-7290 (BH-7033.4): a batch never goes full on one member

Doc: CI-RUNNERS, MERGE-CONDUCTOR

## What changed

- `bin/ci-plan.sh` (`batch_select`): when a merge-queue batch's select answers
  `full: unknown reach (<p>)` or `full: unmapped path (<p>)`, the batch no
  longer runs the full corpus. `bin/lib/ci-member-reach.sh` (`cmr_union`) plans
  the UNION of the members' selections:
  - each unmapped path leaves the diff and adds the suites with a map row
    under its directory (recursive; `*` rows and the root rows `bin/`,
    `bin/lib/`, `catalog/` do not count; a top-level path takes the rows on
    top-level files only);
  - the infra canaries (`catalog/ci-infra-canary.txt`, or
    `CI_INFRA_CANARY_FILE`) are added;
  - the rest of the diff selects as usual (the always set included).
- The batch is `mode=batch-selected`, `escalation=-`. The reason reads
  `member union (BH-7033.4): <k> unmapped path(s) (<first>): <d> directory + <c> canaries; <rest reason>`.
  The tier step, the regression list and suite reuse then run as for any
  batch-selected batch.
- The union is computed from the tree and the diff only (no network), so each
  shard (`--expect-n`, `CI_PLAN_ESCALATION=-`) plans the same list.
- An escalate row of `catalog/ci-batch-escalate.tsv` (for example
  `.mergify.yml`) still makes the batch full. That check runs before the
  select and did not change. The `full` label still makes the batch full.
- `bin/merge-conductor.sh` calls `fle_tick` (`bin/lib/mc-full-label-expiry.sh`)
  after `bmin_tick` on a Mergify repo. For each closed batch draft whose CI runs
  completed (one run ended `success` or `failure`), it takes the `full` label
  off each OPEN member that has it, with one comment first. Only in merge mode
  (`MERGES=1`); other modes log `FULL_LABEL_EXPIRY would-remove pr=<n> draft=<d>`.
  The attempt marks are `fle <slug>#<draft> <sha12>` (draft) and
  `fle-c <slug>#<pr> <draft>` (comment, so a retried DELETE never comments twice).

## When the union is off (the batch stays full)

One stderr line says why: `ci-plan: member union: off (<why>)`.

- `CI_PLAN_MEMBER_UNION=0` (the rollback).
- The canary list is absent, empty, or has a line that is not a present
  `tests/<name>.sh` (`canary list unreadable (<why>)`). **The list comes from
  #7287 (BH-7033.1). Until it is on main, the union is off on main.**
- The map cannot be built, more than 20 unmapped paths, or another full
  answer on the rest of the diff (an infra path, an empty selection).

## Measured directory sizes (main cfe43dbc, 2,511 suites)

| unmapped path under | directory suites |
|---|---|
| `bin/lib/` | 2,334 |
| `tests/lib/` | 2,491 |
| `catalog/` | 675 |
| `worker/jobs/src/` | 171 |
| a new directory | 0 |

An unmapped path under `bin/lib/` or `tests/lib/` still selects most of the
corpus. It is not `full`, so the tier step trims it and suite reuse applies.
The nightly full run stays the safety net for any suite a union does not select.

## Rollback

- CI: set `CI_PLAN_MEMBER_UNION=0` in the Harness CI workflow env (plan job and
  shards both). Every batch then plans as before this change.
- Conductor: `full_label_expiry.max_drafts` (settings row, default 10) bounds
  the drafts read per tick. To stop the pass, revert the `fle_tick` call.

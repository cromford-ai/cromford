# BH-9403: add-only migrations apply before the merge, for normal PRs
Doc: DB-COORDINATION-SPEC, docs/verification-map/hotfix-migrate.md

## What changed

- New settings row `hotfix_migrate.conf.<project>` (one JSON object), read by
  `bin/lib/hotfix-migrate-knobs.sh`. A key beats the env knob of the same
  meaning. Seeded for `project-6-os` and `project-5` with `"before_merge":1`.
- The `# >>> hotfix migrate stage` block in `bin/lib/rb/result.sh` runs
  `bin/hotfix-migrate.sh` for a normal PR of such a project. Two conditions:
  the build verdict is APPROVE, and the reviewed head (`review-head`) is the
  head the worktree holds. The hotfix kill flag does not apply to this path.
  The row's `before_merge` key is its switch.
- project-6-os: the stage posts an APPROVED review pinned to the reviewed sha
  (only when the live head is that sha). Then it dispatches
  `migrate-branch.yml --ref main -f file=<basename> -f ref=<branch>`, one file
  per dispatch, in file-name order.
- project-5: the stage dispatches Migrate Manual SQL
  (`migrate-manual.yml -f file=<path>`) from the PR branch, one file per
  dispatch.
- Per-file mode reads the run log for one word per file: `applied`,
  `already-applied`, `refused`, `inert`, `failed`. A green run with no word is
  `applied` (project-5's run prints none). `refused`, `inert` and `failed` stop
  the loop and are never dispatched again for that SQL fingerprint. `refused`
  writes 1 alert per (project, PR, fingerprint). `inert` writes 1 alert per
  project per UTC day (the UTC day is in the alert id).
- Before every dispatch the stage reads the PR's live head. If it is not the
  reviewed sha, it dispatches nothing. This holds for both projects and for
  every file.
- A stop before any dispatch writes a `retry` proof: checks not green, the
  quiet window, the dispatch lock, a failed dispatch call, the approval POST, a
  moved or unreadable head. The conductor does not park a `retry` proof.
- project-6's own `gate` check (row `mc.migration_gate_checks.project-6-os`)
  and `migration-ledger.yml` runs are left out of the checks wait. They are red
  until the SQL is applied.
- project-6: the local appliability gate is advisory (`local_gate`). Its report
  goes into the proof, and the workflow's allow-list decides. The needs-quiet
  command is off (`needs_quiet`), because project-6 has no
  `scripts/migration-sql.mjs` and its workflow serialises applies.
- Merge conductor: fragment `bin/merge-conductor.d/bh-9403-before-merge-proof.sh`,
  called first in `mc_mig_hold`. For a normal PR of a before-merge project, an
  `applied` proof for the head's SQL is logged, and production (`mmh_decide`)
  still decides. A `hold` proof parks the PR BLOCKED_HUMAN, so it gets no
  merge-queue label. A `retry` proof or no proof: no change.
- `mc_hotfix_proof` takes `MC_HFP_ANY_LABEL=1` to skip its label gate. Only the
  new fragment sets it.

## One dispatcher

`mc.migration_apply_workflow.<project>` (BH-9368's opt-in conductor dispatch)
stays unseeded. The build stage is the only lane that dispatches the apply
workflow.

## Owed: the first real run

No scratch-database probe ran. The first add-only project-6 PR after this
merge is the proof:
1. Open the PR's proof comment (`<!-- hotfix-migrate-proof ... decision=applied -->`).
2. Copy the workflow run link from it.
3. Record the link in `example-org/project-6#3687`.

Known limit: the project-6 allow-list refuses the `SELECT pg_advisory_xact_lock(...)`
line. Until the project-6 fix lands, such a file comes back `refused`: 1 alert,
the PR parks BLOCKED_HUMAN, and a person applies it by hand.

## Kill switch

`bin/jobs-client.sh setting-set hotfix_migrate.conf.<project> '{}'` (or set
`"before_merge":0`). Hotfix PRs keep their own stage either way.

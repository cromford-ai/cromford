# A conflict only in a generated file is regenerated, never parked (BH-6000 part 1)

Doc: MERGE-CONDUCTOR

## What happened

On 2026-10-11 the merge conductor had parked these PRs `conflict-unresolvable`: #5420 and its stacked
children #5443, #5454 and #5613, plus #5892, #5956 and #5907. Some had been parked for more than 1000 minutes.
Each one adds a `worker/jobs/schema.d/` fragment and re-renders `worker/jobs/schema.sql`. Any two such PRs
conflict on `schema.sql` after one of them merges. The conductor's conflict resolver had no rule for that file:
`config/regenerated-paths.conf` named only `docs/notes/INDEX.md`.

## What changed

1. **The registry.** `config/regenerated-paths.conf` and its compiled twin `MC_REGENERATED_PATHS_DEFAULT`
   (`bin/lib/mc/rebase.sh`) name each committed generated file with the command that renders it:
   - `worker/jobs/schema.sql`: `bin/schema-build.sh --write`
   - `rules/CLAUDE.md`: `bin/render-rules.sh --write`
   - `docs/PR-OWNERSHIP.md`: `bin/render-doc-sections.sh --write`
   - `docs/notes/INDEX.md`: `bin/render-doc-index.sh`

   On a main merge (`mc_rebase`, `bin/lib/rebase-job.sh`), `mc_resolve_conflicts` re-renders such a path over
   the merged tree after every other path is settled. A merge that also conflicts in a hand-written file still
   fails and is parked, as before.
2. **Restacks too.** A stacked child's restack (`mc_restack`, `git rebase --onto`) that stops only on
   regenerated paths now re-renders them and runs `rebase --continue` (`mc_rebase_regen_continue`). It does
   this for every replayed commit that stops. Before, any stop was a conflict.

## Operating

- Log line: `regenerated path worker/jobs/schema.sql resolved by re-running bin/schema-build.sh --write`.
- A new committed generated file: add one line to `config/regenerated-paths.conf` and the same line to
  `MC_REGENERATED_PATHS_DEFAULT`. `tests/regenerated-path-conflicts.bh-1162-test.sh` fails when they disagree.

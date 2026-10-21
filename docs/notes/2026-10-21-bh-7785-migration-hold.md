# The merge conductor holds a READY PR whose migration is not in production (BH-7785)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

On 2026-10-20 at 22:10Z the conductor put example-org/project-6 #2113 in the
Mergify queue. The PR added migration 0423, and production did not have it.
The conductor now asks production before it enqueues or merges.

- `pr_worker` in `bin/merge-conductor.sh` calls `mc_mig_hold` directly after
  `mc_classify`. The function is in the fragment
  `bin/merge-conductor.d/bh-7785-migration-hold.sh`. The call is above every
  arm that adds the queue label, posts `@mergifyio queue` or merges.
- `mc_mig_hold` acts only on a READY row. It calls `mmh_decide` in
  `bin/lib/migration-hold.sh`:
  1. Read the globs row `mc_migration_hold.globs.<project>`. No row: nothing
     else is read and the row stays READY. An unreadable row: one log line,
     not gated this tick.
  2. Read the PR's files (`pulls/<n>/files`, paged). Keep only files with
     status `added` that match a glob. A glob is relative, its segments use
     `[A-Za-z0-9_.*-]`, and `*` does not cross `/`. `**` and `..` are dropped
     with one log line.
  3. No match: the row stays READY. No probe.
  4. If `mc_migration_hold.apply_lane.<project>` names a lane, the row is held
     for that lane. No probe, no comment, no alert.
  5. Else `GET <DATA_LANE_APP_BASE>/api/internal/migrations/status` with
     `MIGRATION_TOKEN` from `env/<project>.env` (token in a 0600 header file).
     Each name must match an object in `.applied[]` by its `.filename`. The
     name of `prisma/migrations/0423_x/migration.sql` is `0423_x`, and of
     `x/0423_x.sql` is `0423_x`.
- All applied: one log line, the row enqueues as before.
- Missing, or the probe unreadable (non-2xx, timeout, not JSON, base or token
  not set): the row is `WAIT_CI` with the reason
  `HELD_MIGRATION <names>: <detail>`. One PR comment (hold-comment kind
  `migration`) names the migrations and the apply step. One alert per
  (PR, head), deduped by the `MC_ATTEMPTS` line `mighold <key> <head>`. The
  mark is written before the alert. Observe mode logs `WOULD alert`.
- The answer is cached in `state/merge-conductor/migration-hold/<key>` per
  head, globs and apply lane, for `mc_migration_hold.cache_s` seconds. A
  failed files read is not cached. Each write deletes cache files older than
  7 days.
- The gate re-checks on each tick. The tick after the apply (and after the
  cache window) takes the ordinary READY path.

## Knobs

| settings row | value | no row |
|---|---|---|
| `mc_migration_hold.globs.<project>` | space-separated globs | gate off |
| `mc_migration_hold.apply_lane.<project>` | a lane name `[a-z0-9._-]{1,48}` | the conductor probes |
| `mc_migration_hold.cache_s` | seconds | 300 |
| `mc_migration_hold.probe_timeout_s` | seconds, 1 to 60 | 15 |

## Not covered

A PR already in the queue before this ships is not dequeued. The console
`merge` command, the unblock lane, the archie queue, `bin/merge-queue.sh` and
`bin/merge-sweep.sh` do not ask this gate.

## Operator steps

1. For each project to gate:
   `bin/jobs-client.sh setting-set mc_migration_hold.globs.<project> '<globs>'`.
2. For project-6-os: set `mc_migration_hold.apply_lane.project-6-os` to the
   d7 drain lane name, then the globs row, then lift
   `automerge-disabled-project-6-os`.
3. For each probed project, confirm `DATA_LANE_APP_BASE` and `MIGRATION_TOKEN`
   in `env/<project>.env` on the hub and on the Fly conductor host. Without
   them, every migration PR of that project is held "not configured".

Test: `tests/merge-conductor-migration-hold.bh-7785-test.sh`.

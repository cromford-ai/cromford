# The hub migration lane (BH-8704)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

Migration PRs landed through a batch lane on the operator's Mac, one PR at a time, about
30 min each. On 2026-10-28 six PRs waited about 3 h. If the Mac session stopped,
the lane stopped. The merge conductor already held those PRs as
`HELD_MIGRATION ... left to the mac-batch lane` (`bin/merge-conductor.d/bh-7785-migration-hold.sh`).

A new hub lane, `migration` (`bin/migration-lane.sh`, logic in
`bin/lib/migration-lane.sh`), now lands them in batches. Cron:
`cron/lanes/414-migration-lane.cron`, every 10 min, behind `hub-lease.sh check`.

Two registry rows, the `fly-pool-tick` / `fly-pool` shape. `migration-lane`
(`catalog/lanes.d/migration-lane.json`) is the cron dispatcher: with no
argument the script starts one detached `bin/migration-lane.sh <project>` per
fleet project through `pl_dispatch` (`bin/lib/project-lanes.sh`). `migration`
(`catalog/lanes.d/migration.json`) is each project's run and owns the knobs,
so the rows are `lane.migration[.<project>].<knob>` as the ticket names them.
The lanes registry requires a cron lane's id to equal its script name, which is
why one lane has two rows.

## The switch

One settings row per project: `mc_migration_hold.apply_lane.<project>` =
`migration`. The same row makes the conductor hold the PRs for this lane and
makes this lane take them, so the two never disagree. The project also needs a
valid `mc_migration_hold.globs.<project>` row (BH-7785).

No project is switched on by this change. At ship time the lane processes no
project, sends no alert and makes no GitHub call.

## One tick, per enabled project (in parallel)

1. Skip on `flags/automerge-disabled-<project>` or `flags/paused-<project>`.
   The whole lane stops on `flags/lane-off-migration`, `flags/lane-off-migration-lane`
   (the dispatcher) or `flags/automerge-disabled`.
2. Read `MIGRATION_LANE_APPLY_CMD`, `MIGRATION_LANE_DATABASE_URL`,
   `DATA_LANE_APP_BASE` and `MIGRATION_TOKEN` (and the optional
   `MIGRATION_LANE_SETUP_CMD`) from `env/<project>.env`. The file is read, never
   sourced. A missing one: one log line, one warn alert
   `migration-lane-<project>-config` that names the variable (never a value), skip.
3. Hold `locks/migration-<project>.lock` (the per-project runner,
   `bin/lib/project-lanes.sh`, takes it; a run by hand takes it through
   `pl_lock_take migration <project>`). The lane then works in its own bare
   clone `state/migration-lane/<project>/repo`, made once from the shared
   checkout `$MC_REPOS/<project>` (local, hard links). It never changes the
   shared checkout's origin URL and adds no worktree to it. Then
   `pjl_acquire migration <project> <host>-<pid>` with `PJL_TTL_S=LEASE_TTL_S`.
   rc 3: `lease held by another tick — skipped`. rc 1: `lease unreadable — skipped
   (fail closed)`. A trap releases the lease on every exit path.
4. Select: every open non-draft PR on `main` (a list that is not complete forms
   no batch) whose added files match the globs. The gates run on the CURRENT
   head, cheapest first, and the first failure is logged `#N skipped: <why>`:
   1. `mc_ci_state` = `green`
   2. `vd_clears`: a lead or human MERGE / MERGE-WITH-NOTES stands on the head
   3. `vd_box_word` is not `BLOCK` (rc 2 = excluded)
   4. `bg_scan` is clean (a human or lead BLOCK comment or row excludes)
   5. `bg_cr_standing` rc 1 (a standing CHANGES_REQUESTED excludes; rc 2 too)
   6. the `mc-merge-verdict` ledger row is `clear` for this head (fail closed:
      no row, `hold`, or another head excludes)
   7. a file that builds an index `CONCURRENTLY` (any case, outside `--`
      comments) or starts with `-- mk:concurrent-index` is never run by the
      lane. The gate reads `migrations/status` (one GET per tick, cached) FIRST:
      when production lists every such file applied with the checksum at this
      head, the gate passes and the PR rides a batch like any other member (the
      apply command skips an applied file; step 8 proves it before the merge).
      Otherwise the PR is skipped, with ONE comment and ONE warn alert
      `migration-lane-<project>-<n>-concurrent` per (PR, head). The comment
      names the operator step (`npm run db:apply` from the runbook, from that
      head) and says what the lane then does: it merges the PR on its next tick
      once the status shows the file applied and the other gates still pass.
      A file applied under another checksum stays refused.
   8. the ledger row `pr <project>#<n>` is not `red` or `changed` at this head
   Before the gates: when `origin/main` itself holds a concurrent-index file
   that production has not applied (merged by hand before the operator step),
   no batch forms. The apply command runs every pending file of main, so that
   file would run inside the batch apply. One log line and one warn alert
   `migration-lane-<project>-main-concurrent` name the file.
5. Sort by the smallest migration name (the timestamp) and take `BATCH_MAX`. A PR
   whose row is `solo <head>` goes alone.
6. Batch branch `migration-lane/<project>/<id>`: a worktree at `origin/main`,
   then `git merge --no-ff` of each head in order. A merge that fails is aborted
   and that PR is dropped (`#N dropped: conflicts with main or an earlier member`);
   the rest go on. Push, then ONE draft PR `migration batch <id>: #a #b`. Its body
   says never merge it and carries a `Parked:` line so `bin/pr-owner-sweep.sh`
   reads it as parked. The conductor manages only `ticket/*` branches.
7. ONE CI: poll `mc_ci_state` on the batch head every `CI_POLL_S`, renewing the
   lease before each poll, up to `CI_TIMEOUT_S`.
   - red: close the batch. Members of a batch of 2+ get `solo <head>`; the member
     of a 1-PR batch gets `red <head>` and waits for a push. One critical alert.
   - timeout: close, one critical alert, no row changes.
   - lease lost: `lost`, close, nothing applied or merged.
8. Apply, when CI is green:
   1. Re-read each member: open, head equal to the staged head, every gate
      passes again. Else `#N dropped: <why>`.
   2. Each file at the staged head must have the staged sha256, else
      `#N refused <file>: changed since staging`.
   3. One GET of `<DATA_LANE_APP_BASE>/api/internal/migrations/status`. A batch
      file already in `.applied[]` under ANOTHER checksum is refused the same way
      and the row gets `changed <head>`. Unreadable: `failed`, critical alert,
      nothing applied.
   4. The apply tree `state/migration-lane/<project>/apply` is reset to
      `origin/main`, and only the members' SQL files are copied in. The code that
      runs with the production credential is main's. The apply command runs
      every pending file of that tree, so a migration that is on main but not
      yet in production runs in this batch too. The lane does not refuse it
      (main is the truth; a concurrent one already stopped the batch at step 4),
      but it logs `batch <id>: main's <file> is not in production yet; this
      apply runs it too` and adds the line to the batch summary.
   5. `MIGRATION_LANE_SETUP_CMD`, when set, runs only when `package-lock.json`
      changed since `setup.sha`.
   6. `MIGRATION_LANE_APPLY_CMD` runs under `timeout APPLY_TIMEOUT_S` with
      `DATABASE_URL` in its environment only. Its output goes to
      `state/migration-lane/<project>/apply.out`. The lease is renewed while
      it runs. A refused renew writes `lease-lost` in the tick's temp dir (a
      file, because the command runs in a subshell); the command finishes, and
      then the batch ends `lost` and merges nothing. A lease lost during the
      setup command ends the batch `lost` before the apply.
   7. A second status GET. `#N applied <file>` is written only for a file the
      ledger shows with the staged checksum. The command's exit code alone never
      counts.
9. Merge each member whose EVERY file is proved, in migration order, through
   `gh_pr_merge_rest` bound to the staged head: `#N merged <sha>` and one comment
   on the PR. A refusal is `#N merge refused: rc <n>` and one critical alert; the
   others still merge. Then a summary comment on the batch PR, close it, delete
   its branch.

## Harness root

`bin/lib/migration-lane.sh` reads `H` as `${HARNESS:-${H:-}}`. When both are
empty, `ml_tick` prints `migration-lane: HARNESS and H are empty; refusing to
run` and does nothing, so no path becomes `/logs/...` or `/state/...`.

## Records

- `logs/migration-lane.log`: `<stamp> [<project>] #N applied <file>`,
  `#N merged <sha>`, `#N dropped: <why>`, `#N skipped: <why>`, `batch <id> <status>`.
- Jobs ledger kind `migration-lane`:
  - `batch <project>`: status `ci | applying | merging | done | red | timeout |
    failed | lost`, detail JSON `{id, branch, pr, head, members:[{n, head,
    files:[{path, name, sha256}]}], dropped, summary}`. Overwritten per batch.
  - `pr <project>#<n>`: status `solo | red | concurrent | changed`, detail
    `<head> <why>`. Overwritten per head.
- Retention:
  - `batch <project>`: one row per project, overwritten per batch.
  - `pr <project>#<n>`: written only for an exception (solo, red, concurrent,
    changed), so most migration PRs never get a row. A row keeps value until
    the PR head changes or the PR closes. The fleet `ledgers` table has no
    row-delete route yet, so these rows stay; at tens per month they are not a
    hot-table risk (every read is a point read on the `(kind, key)` key).
  - Local files: the batch worktree is removed every tick. The setup and
    apply commands write `setup.out` and `apply.out` under
    `state/migration-lane/<project>/`; the run before is kept as
    `setup.prev.out` / `apply.prev.out`. At most four files per project.

## Knobs

Rows `lane.migration[.<project>].<knob>` (seeded by
`worker/jobs/schema.d/202611030555-bh-8704-migration-lane-settings.sql`,
registry `catalog/lanes.d/migration.json`):

| Row | Default | Range | What |
|---|---|---|---|
| `batch_max` | 6 | 1..20 | PRs per batch |
| `ci_timeout_s` | 3600 | 300..10800 | CI wait, counted as `ci_poll_s` per poll |
| `ci_poll_s` | 60 | 15..600 | seconds between CI reads |
| `lease_ttl_s` | 900 | 60..900 | lease TTL asked for |
| `setup_timeout_s` | 900 | 60..3600 | setup command wall time |
| `apply_timeout_s` | 1800 | 60..3600 | apply command wall time |

`MIGRATION_LANE_APPLY_CMD`, `MIGRATION_LANE_SETUP_CMD` and
`MIGRATION_LANE_DATABASE_URL` are `settable: false`: commands and a credential
live only in the sealed env file on the hub.

## Operator steps to switch a project on (project-6-os first)

1. In `env/<project>.env` on the hub, set `MIGRATION_LANE_APPLY_CMD` (project-6:
   `node scripts/db/apply-sql.mjs`), `MIGRATION_LANE_SETUP_CMD` (for example
   `npm ci --ignore-scripts`) and `MIGRATION_LANE_DATABASE_URL`. Check that
   `DATA_LANE_APP_BASE` and `MIGRATION_TOKEN` are set.
2. Stop the Mac batch lane (`~/.claude/mk-drain/batch-np2.sh`,
   `auto-land-queue*.sh`). Two lanes must never land the same PRs.
3. `PUT /api/settings` `mc_migration_hold.apply_lane.<project>` = `migration`.
4. Read `logs/migration-lane.log` after the next tick and the first
   `migration batch <id>` PR.

## Known limits

- The apply command's ledger contract is taken from the plan's read of
  project-6 (`schema_migration`, sha256 of the file bytes, `filename` = the base
  name). This box has no project-6 clone, so the checksum shape is not verified
  here.
- The batch CI is whatever runs on the draft PR's `pull_request` event. A repo
  whose workflows skip drafts, or raise no run for an App-token PR, reads `none`
  until `ci_timeout_s`, and the batch then ends `timeout` with a critical alert.
- A member merge refused because the repo requires an up-to-date branch is
  recorded and alerted, never forced. Its migration is applied, so the
  conductor's own migration probe sees it applied on its next tick.

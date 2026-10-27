# Where harness state lives

This page lists each kind of harness state and its store now. It is the
companion of the state ratchet (`tests/no-state-files.bh-4159-test.sh`) and of
the rollout #4141 ("files to the DB").

The writer counts on this page are from `tests/no-state-files.bh-4159-test.sh
--list-segments` at main `63f61c581`. A count is the number of raw `bin/`
write sites (`>`, `>>`, `touch`, `mv`, `cp`, `ln`, `mkdir`, `rm`, `rmdir`,
`tee`) whose path has that first segment under `state/`. A count above 0 means
the directory is still written. It does not mean the file is the authority: a
dual write (the file as a mirror of a row) counts too. Run the command again
for the live numbers.

## Store kinds

| Kind | What it means |
|---|---|
| D1 table | A jobs-worker table (`worker/jobs/schema.d/`) is the record. |
| ledger row | A `ledgers` row (`kind`, `key`, `status`, `detail`) is the record. |
| settings row | A `settings` row is the value. A box reads it DB-first and keeps `state/settings-cache.json` as its last-good copy. |
| flag row | A `harness_flags` row (`bin/lib/flags.sh`). A box keeps `state/flags-cache/` as its last-good copy. |
| rows + file | The row is written, and the file is still written or read as a fallback. |
| cache | A rebuildable local copy of rows or of a vendor answer. Allowlisted. |
| box-local | It belongs to this box only (identity, local clocks, scratch). Allowlisted. |
| file | The file is still the record. |

## Paths in `catalog/state-paths.json`

The catalog classes each path (BH-5005, BH-7431). `bin/state-paths-guard.sh`
refuses a NEW script that writes a `rows` path. The ratchet allowlists every
`cache` and `box-local` path.

| Path | Class | Store now | Authority | Raw writers left | Moved by |
|---|---|---|---|---|---|
| `state/pool` | rows | rows + file | pool spawn, terminal and hold rows | 14 | BH-5001 |
| `state/fly-pool` | rows | rows + file | `build_queue` claim with machine id | 54 | BH-5001 |
| `state/claims` | rows | rows + file | `job_claims` | 5 | BH-5002 |
| `state/pr-owners` | rows | rows + file | `pr_owners` | 7 | BH-5003 |
| `state/build-notes` | rows | rows + file | the `build_note` ledger row | 27 | BH-5003 |
| `state/daily-digest` | rows | rows + file | the digest send-once ledger row | 10 | BH-5003 |
| `state/build-queue` | rows | rows + file | `build_queue` | 28 | BH-5000 (`build_queue_rows_only`) |
| `state/merge-queue` | rows | rows + file | `merge_queue` | 27 | BH-5000 (`merge_queue_rows_only`) |
| `state/deploy-queue` | rows | rows + file | `deploy_queue` | 6 | BH-5000 (`deploy_queue_rows`) |
| `state/remote-results` | rows | rows + file | `pool_record_files` rows and the pool-result ledger row; the consumer cursor as `rr-*` ledger rows | 11 | BH-7429, BH-2643, BH-7803 |
| `state/settings-cache.json` | cache | cache | settings rows | allowlisted | BH-4155 |
| `state/gh-etag` | cache | cache | GitHub ETag cache | allowlisted | |
| `state/vercel-deploys` | cache | cache | the deploy snapshot lane's Vercel deploy list | allowlisted | BH-7431 |
| `state/lane-gate` | cache | cache | the lane-gate pause and settings cache | allowlisted | BH-7431 |
| `state/gh-app-tokens` | cache | cache | the GitHub App installation token cache | allowlisted | BH-7431 |
| `state/gh-app-installations.json` | cache | cache | the GitHub App installation list cache | allowlisted | BH-7431 |
| `state/model-routes` | cache | cache | the model route answers cache | allowlisted | BH-7431 |
| `state/flags-cache` | cache | cache | the last-good cache of flag rows | allowlisted | BH-4153 |
| `state/remote-results-terminal` | cache | cache | the newest kind=build jobs row | allowlisted | BH-7582 |
| `state/unblock-judge` | cache | cache | the `unblock_decisions` claim row (the judge's paid-answer memo) | allowlisted | BH-7724 |
| `state/box-id` | box-local | box-local | this box's identity | allowlisted | |
| `state/box-name` | box-local | box-local | this box's identity | allowlisted | |
| `state/scratch` | box-local | box-local | scratch space | allowlisted | |
| `state/sibling-serial` | box-local | box-local | this box's sibling wait clock | allowlisted | BH-6374 |
| `state/fly` | box-local | box-local | this hub's Fly app and image pointers | allowlisted | BH-7431 |
| `state/fly-cost` | box-local | box-local | the pool's fly cost send-once ledger | allowlisted | BH-4019, BH-7431 |
| `state/quota` | box-local | box-local | account leases and cooldowns | allowlisted | BH-7431 |
| `state/pool-tailnet` | box-local | box-local | the env-bundle ssh failure counter | allowlisted | BH-7431 |
| `state/preplan-files` | box-local | box-local | pre-plan records of the test-home and planned-files steps | allowlisted | BH-7431 |
| `state/auth-accounts.local.json` | box-local | box-local | this box's Claude account routing overlay | allowlisted | BH-7431 |
| `state/overlap-after` | box-local | box-local | the overlap guard's After: markers | allowlisted | BH-7431 |
| `state/fly-onboard` | box-local | box-local | the fly onboard drain ledger | allowlisted | BH-7431 |
| `state/gh-rest-ledger` | box-local | box-local | this box's GitHub REST quota ledger | allowlisted | BH-7431 |
| `state/dispatch-now` | box-local | box-local | the dispatch-now markers of a console dispatch | allowlisted | BH-7431 |
| `state/dispatch-mode` | box-local | box-local | the hotfix-only start clock | allowlisted | BH-7431 |
| `state/hotfix-announced` | box-local | box-local | hotfix announce-once markers | allowlisted | BH-7431 |
| `state/hold-ambiguous` | box-local | box-local | ambiguous HOLD claim-once markers | allowlisted | BH-7431 |
| `state/alert-line-sent` | box-local | box-local | alert-line send-once markers | allowlisted | BH-7431 |
| `state/blind-list` | box-local | box-local | the GitHub blind-repo tick counters | allowlisted | BH-7431 |

## Other state the rollout moved

| State | Store now | Authority | Raw writers left | Moved by |
|---|---|---|---|---|
| `flags/` (pause, automerge, lanedown, dispatch-mode) | flag row | `harness_flags` | held by `tests/no-flag-files.bh-4154-test.sh` | BH-4153, BH-4154 |
| cost and lane caps (`catalog/cost-caps.conf`, `catalog/lane-caps.conf`) | settings row | `conf.cost-caps.*`, `conf.lane-caps.*` seed rows | not under `state/` | BH-4155 |
| `state/cost` (rollup checkpoints) | ledger row | `cost-final-bill`, `cost-rollup` ledgers | 28 | BH-4158 |
| `state/main-red` | D1 table | `main_red_verdicts`, `main_red_pr_errors`, `main_red_pairs` and kin | 28 | BH-4156 (C2) |
| `state/review-autopilot` | ledger row when `no-twin-ledgers` is up, else file | `review_autopilot*` ledgers | 14 | BH-4156 (C1) |
| `state/merge-conductor` | rows + file when `pr-state-rows` is up | the conductor's held-page and attempt rows | 26 | BH-5000 (`pr-state-rows`) |
| `state/blocked-resolver` | rows + file (the record file stays the authority while it exists) | `br_record`, `br_attempt` ledgers | 82 | BH-7801 |
| iron-law ACCEPT (was `builds/<rec>/iron-law-accepted-<sha>`) | ledger row only | `ironlaw-head-accept` ledger | 0 (file writer deleted) | BH-4157, BH-7804 |
| `state/alerts` | rows + file when `alerts-db` is on | the `alerts` table | not counted (see below) | BH-7802 |
| `state/gh-budget` | file | none yet | 7 | none yet |
| `state/gh-policy-cache` | cache | `bin/lib/gh-policy-cache.sh` | allowlisted (`ALLOW_EXTRA`) | |

`state/alerts` shows 0 in the census only because `bin/lib/alert-state.sh`
builds its path in a function (`_as_dir`). The ratchet cannot see a path that
comes from a function or from another file.

## What stays a file

#4141 keeps these as files on purpose:

- Logs: `logs/`.
- Build artifacts: `builds/<record>/`.
- Pure caches: the `cache` rows above, and `state/gh-policy-cache`.
- Build and test config that versions with the code: `catalog/`, `cron/`,
  `env-templates/`.
- Box-local state: the `box-local` rows above.

None of these is counted by the ratchet. Logs and builds have no `state/`
segment, and caches and box-local paths are allowlisted.

## The ratchet

The ratchet has two halves. Both are delta checks (`tests/lib/ratchet-delta.sh`):
each counts sites per file at the base and at HEAD, and goes red only when the
diff raises a count or adds a file with sites.

- `flags/`: `tests/no-flag-files.bh-4154-test.sh`. Allowlist: the two files
  `bin/lib/jobs/flags.sh` and `bin/flags-import.sh`.
- `state/`: `tests/no-state-files.bh-4159-test.sh`. Allowlist: every first
  segment the catalog classes `cache` or `box-local`, plus `gh-policy-cache`.
  It has no committed baseline, so `--strict` is refused (rc 2).

`bin/state-paths-guard.sh` (BH-5005) is a third, narrower check. It refuses a
script ADDED by the diff that writes a `rows` path.

To add a new allowed path:

1. Add a row to `catalog/state-paths.json` with class `cache` or `box-local`,
   and an `authority` that says what the file is.
2. Put the catalog row and the writer in the same PR. The reviewer reads the
   catalog diff.

New state that other boxes need is a row: a jobs-worker table or ledger
(`bin/lib/jobs/*`), a settings row, or a flag row.

## Not drained yet

No rollout family has 0 raw writers today, so the drain lane deletes none of
them. The drain lane is `bin/state-drain.sh` (C1 of #4159, BH-8443). It runs
daily on every board box and the hub. For each top-level `state/` entry, in
name order, it keeps the entry when:

1. the entry is a `cache` or `box-local` path of `catalog/state-paths.json`, or
   `gh-policy-cache` (`allowlisted`);
2. the entry is any other path of that catalog, a `rows` family (`catalog`);
3. the entry is a symlink, socket or FIFO, or is on another mount (`link`);
4. a key of its name is a fixed string in the deployed `bin/`, `catalog/` or
   the box crontab (`referenced`). The keys are the name, the name with
   `.tmp`/`.new`/`.prev`/`.lock`/`.err` and mktemp suffixes removed, the head
   before the first `.` (4 chars or more) and the tail from the first `.` (5
   chars or more, so `.gate-meta`);
5. something inside it was written in the last `STATE_DRAIN_MIN_IDLE_DAYS`
   (30) days, or its age could not be read (`fresh`, `unreadable`).

Any other entry is drained. The writer census is not the delete test: it does
not see a path built in a function (`state/alerts`), so a 0 count there is
not proof. A `rows` family drains only after a PR removes its catalog row.

`STATE_DRAIN_DRY_RUN` defaults to 1, so a run logs `would-drain` lines and
deletes nothing. A real run archives each drained entry to
`archive/state-drain/<stamp>/<name>.tgz`, reads the archive back, and then
removes the entry. Archives older than `STATE_DRAIN_ARCHIVE_KEEP_DAYS` (90)
are pruned. One run drains at most `STATE_DRAIN_MAX_PER_RUN` (20) entries.
Read a dry run in `logs/state-drain.log` before you set
`lane.state-drain.state_drain_dry_run` to 0.

The hub observable is the count of files under `state/` whose first segment
is not allowlisted. `bin/state-drain.sh --report` prints those files, and each
run writes the count as `unallowlisted_files=<n>` in `logs/state-drain.log`
and in the `state_drain` ledger row. The count is above 0 until the rollout
families below lose their writers and their catalog rows.

| Family | Raw writers left |
|---|---|
| `state/blocked-resolver` | 82 |
| `state/fly-pool` | 54 |
| `state/cost` | 28 |
| `state/build-queue` | 28 |
| `state/main-red` | 28 |
| `state/merge-queue` | 27 |
| `state/build-notes` | 27 |
| `state/merge-conductor` | 26 |
| `state/pool` | 14 |
| `state/review-autopilot` | 14 |
| `state/remote-results` | 11 |
| `state/daily-digest` | 10 |
| `state/gh-budget` | 7 |
| `state/pr-owners` | 7 |
| `state/deploy-queue` | 6 |
| `state/claims` | 5 |

At main `63f61c581` the census counts 2061 raw `state/` write sites over 352
first segments. 177 of them have a dynamic first segment (`state/$x`, a bare
`$H/state`). Most of the other segments are lane-private files that the
rollout did not name. To see them all:

```bash
HARNESS_TEST_SANDBOX=1 tests/no-state-files.bh-4159-test.sh --list-segments
HARNESS_TEST_SANDBOX=1 tests/no-state-files.bh-4159-test.sh --list
```

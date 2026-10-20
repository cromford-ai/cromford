# The conductor re-checks migration numbers right before it queues a PR (BH-7671)

Doc: MERGE-CONDUCTOR

## Why

BH-7398 (#7417) renumbers a branch-added migration at the build and at a
conductor rebase. It did not check again at the queue step. On 2026-10-20
project-6 #2055 (`prisma/sql/0336_search_source_budget.sql`) was approved at
06:09Z and queued by the conductor. Main had taken 0336 at 06:10Z
(`0336_schedule_zone_backfill_run.sql`, merged in a local batch, not through the
conductor). A person dequeued the PR and renumbered it to 0361 by hand.

A merge outside the conductor (a local batch, a Mergify batch) can land after a
PR's last rebase, so the number in the PR can be taken by the time it queues.

## What changed

- New pre-queue hook `bin/lib/mc-prequeue.d/migration-numbers.sh`
  (`pq_mignum_wanted`, `pq_mignum`). `pq_gate` (`bin/lib/mc-prequeue.sh`) calls
  it after the restamp step, so it runs in both pre-queue callers: the READY arm
  of `bin/merge-conductor.sh` and the requeue gate after an ejection
  (`ec_requeue_gate`, `bin/lib/mc-eject-cause.sh`).
- The check reads the head's ADDED migrations against current main and every PR
  that is IN the merge queue (`MNR_HEAD=<head> MNR_OPEN_QUEUED_ONLY=1
  mnr_check`, read-only, under the project's git lock). A head that adds no
  migration stops at one local `git diff`: no lock, no REST read.
- On a collision the hook runs `mnr_fix` (the BH-7365/BH-7398 path: every
  self-reference, lock keys, bare numbers, one commit with `Union-resolved:`
  trailers) in a temp detached worktree, pushes with `hold_push` (lease on the
  head, HOLD re-read), proves the push with `ls-remote`, and answers `pushed`.
  `pq_gate` then holds: the PR is not queued this tick.
- Nothing rebinds the approval for that push. The new head has no head-bound
  verdict, so the conductor reads it as HEAD_MOVED and spawns the head-bound
  re-review. `bin/lib/lead-carry.sh` does not carry a lead MERGE across a
  migration renumber (`restamp_same` refuses it).
- Under `REBASE_ON_POOL` the hub pushes no PR branch (BH-486). The hook queues
  one pool rebase per head (`mc_pool_rebase_enqueue`) and holds; the pool job's
  `mnr_fix` does the renumber.
- `bin/lib/migration-renumber.sh` learns "queued". The open-PR rows carry a
  queued flag from the PR's labels: `$MC_MERGIFY_LABEL` (default `merge-queue`),
  `queued` or `checking`, and no `dequeued` label (the `mc_queue_state` label
  rule). A queued PR takes its numbers whatever its PR number, because it lands
  first. This applies at a rebase and pre-PR too, so the queue check and the
  renumber agree. `MNR_HEAD=<sha>` makes a check read that commit in place of
  HEAD. `MNR_OPEN_QUEUED_ONLY=1` lists and fetches only the queued PRs.

## Log lines

```
<key> MIGRATION_RECHECK <pushed|held|refused|could-not-run> head=<h12> new=<n12|-> main=<m12> moves=<n> reason=<text>
<key> MIGRATION_RECHECK note head=<h12> reason=<the lib's stderr line>
```

- `pushed`: written only after `hold_push` rc 0 AND `ls-remote` shows the new sha.
- `held`: a busy git lock, a failed fetch, a HOLD on the ticket, or a pool
  rebase queued. One line per head (`mignumheld` or `mignumpool` attempts mark).
- `refused`: terminal (a decline, a push refusal, no branch). One `mignumfail`
  mark per head, one warn alert `MIGRATION_RECHECK`, and the next tick holds with
  no git.
- `could-not-run`: the check could not read (`mnr_check` rc 2). The gate goes on.

## Knob

`MC_MIGRATION_RECHECK` (lane `merge-conductor`, default 1, 0 = off; per project
`lane.merge-conductor.<project>.mc_migration_recheck`). The hook is off by itself
for every project with no `migration_renumber.dir` settings row, so today it runs
for project-6-os only.

## Ticket item 2: the Mergify batch fails fast on a duplicate number

No code. The plan read example-org/project-6 main on 2026-10-20 (read-only clone):

- `.github/workflows/ci.yml`, step `Lane`: `case "$HEAD_REF" in
  batch/*|mergify/merge-queue/*) IS_BATCH=true`, then `ARGS+=(--full)`. A
  Mergify batch PR runs the full lane.
- The full lane runs the unit suite in 4 shards with
  `--exclude 'tests/unit/*statement*.test.ts'`. The exclude does not match the
  migration test.
- `tests/unit/migration-numbers.TK-996.test.ts` (TK-996) refuses two files that
  share a prefix outside `LEGACY_DUPLICATES`. The duplicate rule reads
  `readdirSync(prisma/sql)` and needs no git history.

The BH-7671 build box could not reach GitHub, so the build did not read these
files again.

# A merge to main re-offers a rebase to every open main-based PR

Doc: MERGE-CONDUCTOR

**What changed.** `bin/merge-conductor.sh` gained one arm, `land_rebase_arm`,
that runs for every PR after `mc_transition` and before the `case "$STATE"`
arms. It fires only when this project's base branch has a sha the conductor has
not handled yet, and then it offers each open base-based PR one mechanical
rebase.

- `tick_project` reads the base sha once per project per tick with
  `mc_land_main_sha` (one authenticated `git ls-remote`, no `gh` budget) and
  compares it with `state/merge-conductor/land/<project>`. Changed sha sets
  `LAND_FIRE=1` for that project's workers. A missing state file is a BASELINE:
  the sha is recorded and nothing fans out. An unreadable sha fires nothing and
  leaves the recorded sha where it was.
- `land_rebase_arm` gates in this order: the kill flag and `LAND_FIRE`; the
  per-(PR, sha) marker `landrebase <key> <sha>` in `attempts.txt`; the base
  (`baseRefName` must be the project base); the state whitelist
  `WAIT_CI|WAIT_REVIEW|HEAD_MOVED`; Mergify's `dequeued` label; a head-bound
  re-review running on this head; observe mode; then `mc_land_needed`.
- `mc_land_needed` answers 0 rebase it, 1 already contains the base sha,
  2 conflicts (stdout: the paths), 3 could not tell. It is `mc_merge_tree`
  followed by `git merge-base --is-ancestor` in the same funnel clone, so it
  writes no ref, no worktree and no commit.
- The spawn reuses what already exists: `mc_rebase` inline when
  `mc_pool_rebase_enabled` says this project rebases on a pool, and
  `mc_rebase_spawn` otherwise. `mc_rebase_spawn` took an optional seventh
  argument, the admission cap, defaulting to `MC_REBASE_PARALLEL`; the land arm
  passes `MC_LAND_REBASE_PARALLEL`. Every six-argument caller is unchanged.
- The result is read by the existing `rebase_consume`, which is keyed on
  (slug, num, head) and does not care which arm spawned the job. So approval
  rebinding by patch-id and `mc_rebase`'s own rebind keep working exactly as
  they did; nothing here invents a second rebind.

**Why.** Before this, a merge to main was an event the conductor did not act
on. The only rebase path starts at `NEEDS_REBASE`, which GitHub only reports
once the PR is DIRTY, and `merge_tree_clean` then declines even that when the
head still merges cleanly. So an open PR sat on the base it was cut from until
it CONFLICTED — and a conflict is the expensive way to learn main moved,
because by then the rebase is not mechanical any more and the ticket is on
`bin/blocked-resolver.sh`'s ladder.

**The intent conflict, declared.** The W2-D header in the `NEEDS_REBASE` arm
says a clean head is left alone because a moved head costs a re-review. Issue
#870 asks this lane to bring exactly those clean heads current on every
landing. We trusted the ticket: it is newer and it is scoped to a separate arm.
`merge_tree_clean` and the `NEEDS_REBASE` arm are not modified — the W2-D
header gained one sentence naming the land arm as the deliberate exception, and
the narrower claim that block was written for still holds.

**What it touches.**

- State: `state/merge-conductor/land/<project>`, one line, the last base sha
  whose fan-out COMPLETED, written atomically and written last.
  `state/merge-conductor/attempts.txt` gains `landrebase <key> <sha>` lines, the
  per-(PR, sha) idempotency key, written only AFTER a spawn or queue succeeded.
- Knobs: `MC_LAND_REBASE` (default 1; `0` restores the pre-BH-870 conductor
  byte for byte, including the ls-remote) and `MC_LAND_REBASE_PARALLEL`
  (default 4, `0` = unlimited) in `env/global.env`.
- Counters, on the existing per-(tick, project) files: `landspawned`,
  `landcurrent`, `landconflict`, `landskipped`, `landdeferred`, `landwould`.
  A land rebase also counts on `rebases`, because it is one.
- Log vocabulary: `LAND baseline`, `LAND <base> moved <old8> -> <new8>`,
  `LAND: <base> sha unreadable this tick`, `LAND_REBASE_SPAWNED`,
  `LAND_REBASE_QUEUED`, `LAND_SKIP parked …`, `LAND_SKIP Mergify dequeued …`,
  `LAND_CONFLICT`, `LAND_DEFER`, and the per-project summary
  `LAND <base> <sha8> handled: …` / `… PARTIAL: …` / `… observe mode: …`.
  `grep ' LAND' logs/merge-conductor.log` is the whole lane.

**Deferred is not dropped.** A spawn refused at the cap, a PR another worker's
lock held, a re-review in flight, a merge test this tick could not run — each
increments `landdeferred`, writes NO marker, and stops `tick_project` recording
the sha. The next tick re-offers exactly those PRs; the ones already handled
are held off by their markers. That is why the summary line says PARTIAL rather
than handled, and names the count.

**What it deliberately does not do.**

- It does not touch `MC_REBASE_BUDGET`. That budget rations the steady-state
  `NEEDS_REBASE` spend, and the point of the ticket is that a landing is not
  rationed by it. The ceiling is `MC_LAND_REBASE_PARALLEL`.
- It does not rebase a `READY` row (one merge away; moving the head costs that
  merge a CI cycle), a `QUEUED` one (the queue provider owns the head), a
  `NEEDS_REBASE`/`REBASING` one (the existing path owns it), a `STACKED_WAIT`
  one (not base-based), or a terminal.
- It does not use `git rebase --onto`. `mc_rebase` merges the base into the
  branch, which is what keeps the reviewed shas and the patch-id rebind alive; a
  true rebase rewrites every sha and carries no rebind (`mc_restack` says so).
- It does not close or supersede PR #886, the first attempt at this ticket.

**Still owed.** The acceptance line "median open-PR age on cromford,
measured before and after" is an operator measurement, not code. The query is
in `docs/verification-map/land-rebase.md`. Everything else here is proven by
`tests/land-rebase.bh-870-test.sh`, which drives the real `bin/merge-conductor.sh`
against a scratch harness with a fake `git` and `gh`.

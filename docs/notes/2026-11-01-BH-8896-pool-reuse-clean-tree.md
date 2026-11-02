# BH-8896: a fix round on a reused pool machine reported the previous job's build

## What happened (project-6-os, 2026-11-01, records on bh-hub-2)

- 10:11Z: machine d8d99e47a11198 spawned for TK-3496 (PR #3512, head 708294bb). Reaped at 11:20:23Z with PR_CREATED.
- 11:20:28Z: the pool reused it for FXR-1465-f6f76243, the fix round for TK-3508 / PR #3511 (head 18b97ed0).
- 12:00:25Z: the reap logged `FIX_ROUND_FINISHED terminal finish=ok` and closed the row done.
- The FXR record held `reviewed-sha` = 708294bb and a pipeline.log with 104 TK-3496 lines and 0 TK-3508 lines. PR #3511 got no new head.

## The cause

1. The reuse cleanup in `next_job_or_destroy` (bin/fly-pool.sh) cleaned `/run/harness` and the build slot. It left `/data/harness/builds/*`. After the reuse, TK-3496's build dir was the newest dir on the machine.
2. A fix round has no build dir and its RESULT has no `BUILD_DIR:` line. `pool_record_write` (fly/builder-runner.sh) and the hub's ssh pull then took the newest dir: TK-3496's.
3. The FXR reap read only the word, so it said `finish=ok` over another job's files.

The round itself builds its tree from `origin/<PR branch>`. We could not read its log (it is on the machine), so we did not prove which tree it ran on. Change 3 below stops a round on a wrong tree either way.

## The six changes

1. **A clean build root on reuse** (`next_job_or_destroy`). Before the handoff, every `/data/harness/builds/*` dir whose name does not start with `<project>-<next key>-` moves to `/data/harness/builds.prev/`. The machine answers `BUILDSASIDE ok moved=<n>` or `BUILDSASIDE failed`. `failed` destroys the machine and hands the row back. A key or project that is not `[A-Za-z0-9._-]+` is never handed the machine.
2. **An FXR record posts no build dir** (`pool_record_write`). Build keys keep the `BUILD_DIR:` read and the newest-dir fallback.
3. **The round checks its tree** (`bin/lib/fix-round-tree.sh` `frt_check`, called in `br_fix_round` after the worktree add). HEAD must be on `brfix/<cap_key>` and equal the PR head (or descend it on a reused checkpoint). If not, the round finishes setup-blocked with `FIX_ROUND_WRONG_TREE: …` and makes 0 agent calls. `frc_run_pool` prints the word `FIX_ROUND_WRONG_TREE … finish=<ok|409|failed>`, and the reap closes the row failed. An unreadable HEAD is not checked (fail-open, one log line).
4. **The reap refuses a foreign record** (`# >>> pool fixround reap`). A fix round writes no `reviewed-sha`. An FXR record with a non-empty `reviewed-sha` is `wrong-tree`: the row is failed, the record files move to `$LOCAL/wrong-tree/`, one ALERTS line, and the reap line says `wrong-tree`, not `finish=ok`.

5. **The adopt reads the pool row** (`br_fix_adopt`, `frt_adopt_gate` in `bin/blocked-resolver.d/bh-8896-fix-round-tree.sh`). A pool machine posts its own finish, so the hub adopt can run before the reap. The adopt now reads the FXR pool row first, with the same `/api/queue` read as `frp_put`. `queued` or `claimed`: the adopt is held this tick and writes nothing. Unreadable: the adopt runs as before (fail-open, one log line). `failed` with a reason that starts `wrong-tree:` (change 4 writes it): the round is wrong-tree.
6. **A wrong-tree round is refunded** (comment 6558202642). After the adopt CAS, `frt_refund` runs in place of the rung the round answered (`terminal`, `rebuild-fresh`, `done`). It writes `fixround_refunds` +1 and one `fix-round-wrong-tree` attempt in one record write. `br_fix_cap` (bin/lib/br/record.sh) adds `fixround_refunds` in every branch, so the ladder offers the fix round again. `fixrounds` and the `pr_attempts` rows are not lowered: the refund raises the cap, not the count. A `setup-blocked` or `box-paused` round spent nothing and is not refunded. The head reset (bin/lib/br/headgate.sh) and the PR reset (bh-8339) set `fixround_refunds` to 0. Absent, the field is 0, so every cap today is unchanged.

Known gap: `br_save`'s ledger mirror does not carry `fixround_refunds`. A wiped hub restores the record without the refund, so the cap reads lower (no over-spend). The prepass cost rank (`br_prepass`) also does not add the refund; it changes the order of candidates only, not the rung.

## Operator step for project-6-os #3511

FXR-1465 is already adopted and its pool row is `done`, so this change does not refund it. To give #3511 its fix round back, on the hub:

1. Find the cap key: the resolver log line for #3511 names the record file `state/blocked-resolver/project-6-os/<cap-key>.json`.
2. Run `jq '.fixround_refunds = ((.fixround_refunds // 0) + 1)' <file> > <file>.new && mv <file>.new <file>`.

## builds.prev: one generation

`builds.prev/` is emptied before each move, so it holds only the previous job's dirs. A pool machine is ephemeral, so there is no retention job. The next key's own dir stays in `builds/`, so a same-key retry can resume. The hub reads the reaped job's files before `next_job_or_destroy` runs, so the move never hides them.

## Which test proves which case

| Case | Test |
|---|---|
| Reuse moves the previous key's dir aside (red on main) | tests/pool-reuse-clean-tree.bh-8896-test.sh R1, R2, R5, R7 |
| A failed move destroys the machine | R3; an older machine with no answer reuses: R4 |
| An FXR record borrows no build dir (red on main) | R6 |
| A round on a wrong tree stops with 0 agent calls | tests/fix-round-wrong-tree.bh-8896-test.sh W1-W7, W9 |
| A normal round is unchanged | W8, W9b, W9c |
| The reap reports wrong-tree, not ok (red on main) | tests/pool-fxr-reap-wrong-tree.bh-8896-test.sh X1, X5 |
| A clean FXR record still closes done | X2, X4; the machine's own word fails the row: X3 |
| `br_fix_cap` with no `fixround_refunds` is unchanged; with 1 it is +1 on every branch | tests/fix-round-wrong-tree-refund.bh-8896-test.sh F1 |
| The adopt is held while the pool row is queued or claimed | F2 |
| A wrong-tree round takes no rung, is refunded, and the ladder offers the fix round again (red on main) | F3 |
| Another failed reason, a done row, no row or an unreadable row adopt as before | F4, F5 |
| A setup-blocked wrong-tree round is not refunded | F6 |
| The head reset and the PR reset clear the refund | F7 |

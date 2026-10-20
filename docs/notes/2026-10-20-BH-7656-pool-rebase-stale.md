# BH-7656: a pool rebase is not handed back while its machine runs

Doc: docs/MERGE-CONDUCTOR.md, docs/verification-map/fly-pool-sweep.md

On 2026-10-20 the project-6-os RB rows were queued at 23:49Z and no machine
started until 01:23Z. At 01:54Z the conductor read them as stale and handed
#1896, #1931 and #1957 back to the hub, while the machines for RB-1957
(8e100ec7349e98) and RB-1975 (7812062b647718) still ran. The hub and the
machine then rebased the same head. The machines had also autostopped with
their RESULT on tmpfs, so the reap failed the rows.

## What changed

1. The stale bound counts from the claim. `mc_remote_rebase_row`
   (`bin/lib/mc/spawn-remote.sh`) reads `claimed_at` for a `claimed` row. Under
   `ROWS_ONLY=1` the claim is the gate just before `fly machine run`. A missing
   or unparseable `claimed_at` uses `enqueued_at` (the old clock). A `queued`
   row still counts from `enqueued_at`. The bound is still
   `MC_REBASE_POOL_TIMEOUT_SECS` (default 5400 s).
2. A live machine blocks the hand-back. Only a row past the bound reads the D1
   machine registry: `GET /api/machines?project=<p>&key=RB-<pr>-<head8>&live=1`.
   A live row reads `running` (`machine <id> live (<state>)`). A failed read
   also reads `running` (`machine lookup failed`) and is read again next tick.
   A 404 or no live row keeps the old rule. On the hub, `mc_rb_state` reads
   `running` past the bound while `state/fly-pool/*/*.json` has the key.
3. The rebase RESULT ends with `TIMINGS: setup=<s> merge=<s> gates=<s>
   push=<s>` (`bin/lib/rebase-job.sh`; `rebase_setup_result` in
   `fly/builder-runner.sh` writes `merge=- gates=- push=-`). `setup` counts
   from `REBASE_JOB_T0`, which the runner sets before the warm-up. The hub
   reap adds `timings: ...` to its `reaped rebase` line.
4. A rebase RESULT survives autostop. The runner writes the BH-2643
   pool-result row for `RB-` keys too, with `detail.result` (the whole RESULT,
   at most 2000 bytes). The reap of a stopped machine takes the row when its
   first word is a rebase word, and the RB apply arm runs as for an ssh read.
5. The runner's idle window before autostop is a settings row:
   `lane.fly-pool.<project>.pool_idle_timeout_s`, then
   `lane.fly-pool.pool_idle_timeout_s`, then 600 s (knob `POOL_IDLE_TIMEOUT_S`).
   A value that is not an integer in [60, 7200] is refused with one log line.
6. The pool rebase runs the project's generate step before typecheck. A
   fresh `git worktree add` never runs `postinstall`. project-6's postinstall
   is `prisma generate`, and its client is written to the git-ignored
   `src/lib/db/__generated__/prisma`. So the pool typecheck was red on a green
   branch. Step 6d of `rebase_job_run` now runs `npm run postinstall` in the
   merged worktree when its `package.json` declares the script and
   `node_modules` exists. A failing postinstall does not stop the job:
   typecheck decides. `pretypecheck` (the registry step) npm runs by itself.
7. A GATE_RED names the first failing file. Typecheck and unit output go to
   one temp log, which is removed on every path. The RESULT first line is
   `GATE_RED typecheck: <line>` (or `unit`), where `<line>` is the first tsc
   error or vitest/jest FAIL line, at most 200 bytes. When postinstall failed,
   ` [postinstall rc=<n>]` follows. With no such line the word stands alone.

Not changed: the hub `mc_rebase` (`bin/lib/mc/rebase.sh`), `bin/lander.sh` and
`bin/merge-queue.sh` make worktrees with no `postinstall` too. A later ticket
can give them the same step.

# BH-9435: pool builder toolchain (pgvector, setup fault, disk headroom, tsc heap, probe)

The hotfix ticket has four scope items. This PR builds all of them in one change (the size gate measured it as within the hotfix limits). Each section below is one child of the plan.

## C1: pgvector in the pool Postgres

The pool image builds pgvector 0.8.1 from its pinned source in the stage `pgvector-build`, against the PG 16 headers. The final stage copies `vector.so`, `vector.control` and `vector--*.sql` into `/opt/pgtest` (`lib/postgresql/` and `share/postgresql/extension/`). At image build time the `bake-pgvector` layer runs `CREATE EXTENSION vector` in a single-user backend as nobody. An error stops the image build. `/opt/pgtest/PGVECTOR_VERSION` marks an image that has the extension.

The sha256 pin is `a9094dfb85ccdde3cbb295f1086d4c71a20db1d26bf1d6c39f07a7d164033eb4`, in `PGVECTOR_PIN_SHA256` (`bin/lib/pgtest-pin.sh`) and `ARG PGVECTOR_SHA256` (`fly/Dockerfile`). Two downloads of `https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.1.tar.gz` gave the same value, and the tarball's `vector.control` says `default_version = '0.8.1'`.

Evidence for the stage, run by hand by the first build of this ticket (branch `ticket/bh-9435`, 2026-11-11) on an Ubuntu 24.04 build box (no Docker on it): the `pgvector-build` commands (`build-essential`, `postgresql-server-dev-16` 16.15, `sha256sum -c` OK, `make` with `OPTFLAGS=""`) built `vector.so`. Copied into a copy of `/opt/pgtest` (16.14) in the `bake-pgvector` layout, the bake's own check as nobody (`initdb`, `postgres --single -c exit_on_error=on`) gave rc 0, `vector = "[1,2]"` and extversion `0.8.1`. Not verified here: a full `fly/Dockerfile` image build.

Evidence from the build box: `CREATE EXTENSION vector` against the current `/opt/pgtest` (16.14) failed with `extension "vector" is not available`. A `vector.so` built outside embedded-postgres (a PG 16 build, pgvector 0.6.2) loaded into a copy of `/opt/pgtest` 16.14 with the same file layout, and `CREATE EXTENSION vector` returned rc 0. So the same-major ABI and the target dirs work.

## C2: a red setup is a named fault

`pgt_setup` keeps its `HARNESS_PG_SETUP: npm run <s> (rc=N)` line. On rc not 0 it adds `HARNESS_FAULT: pg-setup (npm run <s> rc=N)` and returns 4. `HARNESS_SUITE_RUN` then does not run the suite, writes `HARNESS_EXIT: could-not-run`, tears the Postgres down and logs one `HARNESS-VERIFY <phase> fault: pg-setup (rc=N): the suite is not run` line. The serial path (`pgt_run_files`) marks the file `not run: pg-setup failed`, runs no later file and returns 125. Build-discipline rule D70 tells a builder never to narrow the SQL dir or the file set to get past a fault.

Until C1's image deploys with the sha set, every project-6 pool build with the setup row on is could-not-run. That is the intended signal: before this change the same builds ran on a half-applied schema.

## C3: disk headroom before a build

Each build writes one `disk: <MB> MB free on / at build start (<host>, builder_exec=<0|1>)` line to `pipeline.log`, on every machine. When free disk is under `DISK_HEADROOM_MIN_FREE_MB` (row `lane.disk-guard.disk_headroom_min_free_mb`, fallback 8192), the step lists old settled build dirs, oldest first, and TRIMS them: it removes each dir's subdirs and top-level symlinks (worktrees, node_modules, Postgres data) and keeps the dir and its top-level files (RESULT, job.json, markers, plan.md, review.md, pipeline.log). The archive readers in `bin/lib/build-archive.sh` are the duplicate-build guards (launch-fastpath check 17, ticket-identity b2, merged-ticket-advance, fetch-artifact), and they need the dir to exist, so a trimmed dir keeps a merged ticket's build record. A trimmed dir carries `HEADROOM_TRIMMED` and is not trimmed again. Candidates are `builds-archive/<YYYYMM>/*` dirs on every machine, plus settled `builds/` dirs on pool machines only. `DISK_HEADROOM_DRY_RUN` is 1 by default: the step writes one audit line to `logs/disk-headroom.log` and deletes nothing. The step never removes the running build's dir or a dir whose build-key lock is held, and it never fails the build. `tests/disk-headroom.bh-9435-test.sh` H10 proves `ba_has_key`, `ba_dirs`, `ba_path` and `ba_merged_other` answer the same before and after a non-dry-run trim.

Operator step: after one day of audit lines, size the threshold per host, then set `lane.disk-guard.disk_headroom_dry_run` to 0. The build box (a pool machine) had 6804 MB free on a 7964 MB root, under the 8192 default.

ENOSPC 14-day count: the "before" number must come from the hub and box-project-6-os-1 (`builds/*/pipeline.log`, `builds/*/*.txt`, dirs stamped in the 14 days before merge). The build box holds only its own build dir, so it cannot give the number. The "after" count is owed 14 days after deploy (owner: the C3 deploy, due 14 days after merge).

## C4: the tsc heap is a per-project row

`bin/lib/tsc-heap.sh` (`rebase_tsc_heap`) is the one resolver for the post-rebase verify, `bin/rebase-train.sh` and the probe. Order: row `lane.fly-pool.<project>.tsc_heap_mb`, then env `TSC_HEAP_MB`, then 70% of RAM capped at 12288. A repo workflow's `--max-old-space-size` is used only when it is larger than the RAM rule. 6144 is the last fallback when RAM is unreadable. Before this change the workflow's 6144 won over a 16 GB machine, and tsc aborted with exit 134 (TK-3772). `bin/rebase-train.sh` no longer hardcodes 6144.

The seed row `lane.fly-pool.project-6-os.tsc_heap_mb` is 11264 (70% of 16 GiB, rounded down to 1024). It is not a measured peak: the build box could not clone project-6 (egress refused). The `POOL_PROBE project-6-os tsc=<ok|fail:rc>` line is the proof. project-6's `tsconfig.json` has no project references, so a per-reference typecheck does not apply.

## C5: daily pool toolchain probe

The checks must run on the image under test. Only a pool builder has `/opt/pgtest` (with pgvector after C1) and the project's warm clone. A lane-run machine (`fly/lane-run.Dockerfile`) has neither, and the hub is not the pool image. So the probe has a builder half and a hub half, and they meet in the worker `ledgers` table (kind `pool-toolchain-probe`, key `<project>:<YYYY-MM-DD UTC>`). That is the shape `bin/lib/cred-probe.sh` uses for its once-a-day canary.

- Builder half. `fly/builder-runner.sh` calls `bin/pool-toolchain-probe.sh --builder <p>` on the build path, after `warm_up` and the disk guard, and before the PR-adopt preflight. It takes the day's claim with `job_ledger_claim` (status `running`, terminal `ok,fail`, stale after `POOL_PROBE_CLAIM_STALE_S`, default 7200 s). Only the job that wins the claim runs the checks, so one build per project per UTC day pays for them. The checks: a new cluster, `CREATE EXTENSION vector` and a vector cast in a single-user backend, the cluster stopped; then a new shallow clone of `/data/repos/<p>`, `npm ci --prefer-offline` and one `tsc --noEmit` at the `rebase_tsc_heap` value. The job PUTs `ok` or `fail` onto the claim's key, with the verdict line `POOL_PROBE <p> pg=<ok|off|fail:why> tsc=<ok|off|fail:rc> heap=<MB src>` as the detail. It runs in the foreground (BH-9288) and never fails the job. A claim already taken, or a ledger that does not answer, runs nothing. The row `lane.pool-toolchain-probe.<p>.pool_probe_on_builder` = 0 stops this half.
- Hub half. `bin/pool-toolchain-probe.sh --check` runs hourly at :47 behind the hub lease (`cron/lanes/781-pool-toolchain-probe.cron`). For each pool project (`flags/fly-pool-<p>`) it reads today's row, else yesterday's. `fail` gives one `pool-toolchain-<p>` warn alert with the verdict line; the alert state machine dedupes the hourly repeats. `ok` resolves the id. `running`, no row (no pool build ran) or a ledger read error gives one log line and no alert.
- By hand on a pool builder: `bin/pool-toolchain-probe.sh --run <p>` runs the checks and prints the line, with no claim and no alert. On the first build's box this printed `pg=fail:create-extension` with `extension "vector" is not available`, which is the C1 defect on the current image.

The off switch for all three modes is `flags/lane-off-pool-toolchain-probe`. A project with no pool build on a day gets no probe that day. Nothing on its pool toolchain changed or was used that day either.

Ledger rows: one per pool project per day (2 projects today, about 730 rows a year). `ledgers` rows are never deleted by the retention route (claim keys read as history); this kind follows the per-kind archive move of BH-6774 C2, the same as `canary-inference`. The `(kind, key)` unique index serves every read and write here.

## Fix round 3 (merge with main, review findings)

- `pgt_setup` and BH-9835. Main added the `prisma db push` setup form (BH-9835). The merge keeps both rules. A red `npm run <script>` setup is the named fault (rc 4). A red `prisma db push` is evidence and returns 0, so the BH-9835 suite M7 stays as it is.
- `vr_run_files` (`bin/lib/verify-run.sh`, BH-9471). It is the runner of the fresh-main guards and the fix-round repro. A red `npm run` setup now stops the run before any file runs, stops the cluster, and returns `could-not-run` with the `HARNESS_FAULT: pg-setup` line as `VR_WHY` (tests F-VR1 to F-VR3).
- The probe stop timeout is the knob `POOL_PROBE_PG_STOP_TIMEOUT_S` (row `lane.pool-toolchain-probe.<p>.pool_probe_pg_stop_timeout_s`, fallback 30). Test Q9.
- The probe checks disk first. Free MB under `$TMPDIR` below the disk-guard row `DISK_HEADROOM_MIN_FREE_MB` (fallback 8192) gives `tsc=off:low-disk` with no clone and no `npm ci`. That is not a failure, so it raises no alert. Tests Q13 to Q15.
- The probe type-checks the default branch of the warm clone (`origin/HEAD`, else `origin/main`), never the checked-out branch. Neither ref gives `tsc=fail:no-default-branch`. Tests Q10 to Q12.
- The heap row is capped at the RAM ceiling (70% of MemTotal, at most 12288), with source `row-capped`. The project-6-os seed 11264 on a 4 GB machine gives 2743, not an OOM kill. Test K9.
- Not changed: the trim of archived evidence subdirs (`ci-local/`, `fmg/`, `rules-pack/`) when dry run is off. Dry run is the default, so nothing is deleted today.

## After merge

1. Run `bin/fly-image-build.sh` for the pool image right after the merge. The pg-setup fault goes live at merge, and pgvector goes live only with the new image. Until then a project-6 pool build that applies `knowledge_chunk.sql` is `could-not-run`.
2. Count ENOSPC on the hub and on box-project-6-os-1, and add the number to the PR as `ENOSPC 14d before:`. This build box cannot read those build dirs. The command:
   `grep -l ENOSPC /root/harness/builds/project-6-os-*/pipeline.log | xargs -r stat -c %Y | awk -v t=$(( $(date +%s) - 14*86400 )) '$1>=t' | wc -l`
3. Do not set `lane.disk-guard.disk_headroom_dry_run` (`disk_headroom_dry_run=0`) before a person reads one dry-run `dirs=` line in `logs/disk-headroom.log`.
4. Read the first `POOL_PROBE project-6-os` line in `logs/pool-toolchain-probe.log`. `tsc=ok` is the proof that the heap seed passes.

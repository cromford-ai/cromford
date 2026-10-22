# Pool worktree sweep (earlier jobs' worktrees off a reused pool machine)

**What it is:** `bin/pool-worktree-sweep.sh`, run ON a pool machine by
`pool_worktree_sweep` in `fly/builder-runner.sh`. `_run_job` calls it after
`slot_preflight` and before `warm_up` and the disk guard, only when
`POOL_MODE=1`. It removes every entry of `/data/worktrees` that is not kept and
that no live process uses, and answers one line:
`WTSWEEP ok removed=<n> busy=<n> kept=<n> failed=<n> freed_kb=<k>` (rc 0) or
`WTSWEEP unreadable <why>` (rc 2, nothing removed). The sweep never fails a job.

**Why it exists:** BH-8004. TK-1582 deferred 11 times on 2026-10-22 with
`BUILD_DEFERRED disk 100% used on /data` and its queue row went FAILED.

- Pool machines are volume-less (`bin/fly-pool.sh`). `/data` is a directory on
  the machine rootfs; `fly/entrypoint.sh` links `/root/worktrees -> /data/worktrees`.
- The hub reuses a started machine for the next queued job, so the rootfs keeps
  every earlier job's files.
- A pool build skips the slot gate, so `bin/lib/rb/gates.sh` names the worktree
  per key: `/root/worktrees/<project>-<key slug>`. Each new key on a reused
  machine adds one worktree (project-6: about 2 GB of node_modules each).
- `bin/disk-clean.sh` is a box cron lane. Nothing removed these on a pool machine.

**The keep rules:**

| entry | result |
|---|---|
| `<project>-<this key's slug>` (same slug as gates.sh) | kept |
| `<project>-slot1` (the `warm_up` pre-seed) | kept |
| a live process has its cwd at the entry or under it | kept, counted `busy`, logged with the pid |
| a symlink | the link alone is removed, never its target |
| a registered git worktree | `git worktree remove --force --force`, `rm -rf` if that fails, then `git worktree prune`; the branch and its commits stay in the shared repo |
| anything else (other keys, other projects, dot entries) | `rm -rf --one-file-system` |

A keep name is exact, never a prefix (`TK-15820` is not `TK-1582`). An entry
counts `removed` only when it is gone afterwards, else `failed`. Uncommitted
edits in a dead build's worktree are discarded.

**The disk deferral names the machine:** when the guard still defers, the
RESULT is `BUILD_DEFERRED disk <pct>% used on /data on machine <FLY_MACHINE_ID>
(<WTSWEEP line or "no sweep">)`, with the machine id inside the hub's 120-char
`DWHY`. The `fleet_alert` beat carries `machine` and
`detail: builder disk <pct>% on machine <id>`. The hub reads the line through
its generic `BUILD_DEFERRED*` arm; it is not an overlap, lane or dirty-machine
line, so the reuse policy and the deferral count are unchanged.

**How an operator reaches it:** on the pool machine, the runner log line
`worktree sweep: WTSWEEP ok … (rc=N)` (or `worktree sweep: absent` on an older
synced tree) and `/data/harness/logs/pool-worktree-sweep.log` (one line per
removed, busy or failed entry, one summary line). On the hub, a disk deferral
shows in `builds/pool-<project>-<KEY>-*/RESULT`.

**How to drive it:**

| what | how |
|---|---|
| the whole suite (runner order, keep table, refusals, failed removals, hub readers) | `HARNESS_TEST_SANDBOX=1 bash tests/pool-worktree-sweep.bh-8004-test.sh` |
| by hand on a pool machine | `/data/harness/bin/pool-worktree-sweep.sh --root /data/worktrees --keep <project>-slot1` |

**What must never regress:**

- **Before the guard.** The sweep runs before `warm_up` and the disk `df`, so a
  machine full of old worktrees builds instead of deferring.
- **Never a live build.** An entry with a live cwd in it is kept, and so are
  this key's worktree and `<project>-slot1`.
- **Refuse, do not guess.** No root, a relative root, root `/` or no
  `<proc>/self` removes nothing.

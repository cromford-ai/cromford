# BH-1363: the fix round's worktree gets an owner on every exit, and disk-clean gets the backstop

**What happened.** On 2026-09-22 the hub was at 92% disk (87G of 99G).
`/root/harness/tmp/brfix/` held eleven blocked-resolver fix-round worktrees
dated 09-17..09-20, **14 GB** in total (1.8-2.7 GB each for the app repos),
still registered as worktrees in cromford, project-5 and project-2,
with no process holding any of them and the resolver idle. The lead removed all
eleven by hand.

**Cause, in two halves.** `br_fix_round` does remove its worktree on every
PLANNED exit — there were already eleven `git worktree remove --force` call
sites. What was missing:

1. **Nothing owned the directory on an unplanned exit.** Removal happened only
   at the eleven inline call sites; the per-key subshell ran
   `trap 'br_round_end' EXIT`, which freed the ledger row and nothing else. A
   round killed by a reboot, by `update-runners`, by the OOM killer or by an
   operator left the whole checkout behind and nothing ever came back for it.
   (Bash DOES run an EXIT trap when a signal kills it — that trap simply never
   touched the worktree. Measured, not assumed: reverting only the EXIT-trap
   half of this fix turns §1 of the new suite red.) The separate `TERM`/`INT`/
   `HUP` trap earns its place for a different reason: bash runs the EXIT trap
   AT ONCE on a signal, abandoning the wait on an agent that `timeout` has put
   in a process group of its own, so without it the cleanup deletes the
   worktree under a still-running agent — §1b is that case.
2. **Every removal was unchecked.** All eleven sites discarded the rc and wrote
   no line. `git worktree remove --force` genuinely fails on a LOCKED worktree
   (rc 128, directory untouched), and a removal that failed was
   indistinguishable from one that worked.

And nothing else swept them: `bin/disk-clean.sh` stage 3 walks every registered
worktree but KEEPS any whose HEAD is on no remote unless the basename is
`triage-*`. A `brfix/<ck>` checkpoint is local-only by construction, so a leaked
fix worktree was ineligible for that sweep **for ever**.

The leak also wedges the ticket it belongs to: a leftover worktree still holds
`brfix/<ck>` checked out, so once the PR head moves past the reuse guard the
next round's `worktree add -B` fails with
`fatal: 'brfix/x' is already used by worktree at ...` (rc 128, reproduced by
hand while writing this) and the park goes to `br_setup_blocked` every tick from
then on.

**What changed.**

- `bin/blocked-resolver.sh`: one removal path, `br_wt_drop <why> [repo wt]`.
  It escalates `worktree remove --force` → `-f -f` (the locked case) → an
  ANCHORED `rm -rf` (only a path under `$H/tmp/brfix/`) → `worktree prune`, then
  logs `removed the fix-round worktree <path> (<why>)`, or
  `could NOT remove the fix-round worktree <path> ... left for bin/disk-clean.sh`
  if the directory survived all three. `BR_FIX_WT`/`BR_FIX_REPO` are set at the
  `mktemp -d`, before the `worktree add`, so a half-created tree is owned too,
  and the helper clears `BR_FIX_WT` when it drops the round's own tree — the
  explicit call and the trap between them remove once and log once. All eleven
  call sites plus `br_yield_take` now go through it, and no call site reads its
  rc: a cleanup result never rewrites a round's verdict.
- The per-key subshell traps `TERM`, `INT` and `HUP` as well as `EXIT`; the
  signal arm also runs `mc_git_auth_clear`, which until now only ran on planned
  exits, and exits 143. The worktree is dropped BEFORE `br_round_end` frees the
  ledger row, so a slot is never handed back while its scratch tree is still on
  the disk.
- `br_wt_drop` NEVER deletes `brfix/<ck>`. That branch is the record of agent
  tokens already spent, and the reuse path starts from it. Branch deletion stays
  exactly where it was, on the terminal call sites.
- `bin/disk-clean.sh` stage 8: `tmp/brfix/*` and `tmp/state-backup.*`, top level
  only, nothing inside touched for `TMP_SCRATCH_STALE_H` hours (default 24), no
  `/proc/<pid>/cwd` pointing into them and no `run-build|run-triage|agent-call`
  cmdline naming them. Removal goes through the owning repo read from the
  worktree's own `.git` file, and only when that repo is under `$REPOS`. Three
  counters on the summary line: `tmp_removed`, `tmp_freed_kb` (measured before
  the removal, added after the directory is confirmed gone), `tmp_skipped_held`.
  An age that will not parse KEEPS the directory — absent is not zero, and zero
  here would be the epoch.
- `TMP_SCRATCH_STALE_H` is registered in `catalog/lanes.d/disk-clean.json` and
  documented in `env-templates/lanes/180-daily-state-hygiene.env.example`.

**The audit of the other `tmp/` writers** (ask 4 of the ticket). Each one either
cleans up on every exit path it can catch, or is covered by stage 8, or is
deliberately left alone:

| writer | path | verdict |
|---|---|---|
| `bin/batch-resolve.sh` union worktree | `${TMPDIR:-/tmp}/batch-resolve-XXXX` | already clean: `union_cleanup` (`bin/batch-resolve.sh:1419`) runs under the `EXIT` trap at `:1427`. No change. |
| `bin/batch-resolve.sh` clone cache | `$H/tmp/batch-resolve/<slug>` | **NOT swept, deliberately.** It is a reused blob:none clone, one per slug, cloned once and reused across trains — sweeping it converts saved disk into repeated clone traffic on every train. If a box ever needs it bounded, that is a longer window (14d+), not this one. |
| `bin/state-backup.sh` staging | `$H/tmp/state-backup.XXXXXX` (`:199`) | already clean on every catchable exit (`EXIT` trap, `bin/state-backup.sh:209`); stage 8 is now its SIGKILL backstop. |
| `bin/state-restore.sh` | `$H/tmp/state-restore` | **NOT swept.** An operator CLI's explicit `DEST`, written by hand and read by hand. |
| `mc_git_auth` askpass files | `/tmp/mc-askpass-*` | bytes, not gigabytes, and on a different filesystem. Recorded here, not swept. |

**Verification.** `tests/blocked-resolver-wt-cleanup.bh-1363-test.sh` drives the
REAL lane over a REAL repo and bare remote: a round killed with SIGTERM to its
session mid-agent (§1), a group-only SIGTERM that must NOT delete the tree under
a live agent (§1b), a worktree the agent LOCKED so `--force` returns 128 (§2),
the ordinary refusal (§3), a removal that fails everything (§4, both git and rm
refused by fixture shims — root ignores permission bits, so the failure is
injected where the code meets the system), and the success path (§5).
`tests/disk-clean-tmp-scratch.bh-1363-test.sh` drives the real
`bin/disk-clean.sh` over a real repo with four registered brfix worktrees and
every must-NOT-fire neighbour. Both suites were RED against this branch's merge
base before the fix and green after it.

**What this does not fix.** A group-only `kill -TERM` of the lane leaves the
agent running: `timeout` puts the agent in a process group of its own, so the
round's shell stays in `wait` until the agent finishes and cleans up then. And
nothing a shell can do survives SIGKILL or a power cut — that is exactly what
stage 8 is for. No operator restart is needed for the resolver: cron picks up
the new script on its next tick and a round already in flight finishes on the
code it has in memory.

Doc: disk-clean-hygiene, hotfix-lane

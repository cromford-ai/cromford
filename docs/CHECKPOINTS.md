# Lane checkpoints — no finished work is ever lost

**Status:** shipped 2026-09-15. Owner: `bin/lane-checkpoint.sh`, wired into the
EXECUTE stage of `bin/run-build.sh`.

## The incident this exists for

Seventeen lanes died on max-turns in 24 hours and ended "NO PR". The worst of
them was today's project-5 migrations lane: it had **committed twelve files**
and then died before it pushed. Nothing was wrong with the work. The operator
rescued it by hand — `git push` from the box — and it landed as project-5
#1156.

`bin/run-build.sh` has pushed the branch after every commit-producing stage
since 2026-09-11 (`PUSH_BRANCH`, "the tree survives this machine"). That backup
covers every stage except the one that matters: EXECUTE is 40-75 minutes of
editing between the branch being cut and the first push, and the first
`PUSH_BRANCH` call is the line **after** the execute session returns. A session
that never returns never reaches it. On the Fly pool the disk holding that tree
is an ephemeral machine that gets reaped, so "it's still on the builder" is not
a recovery plan either.

## What was built

1. **A heartbeat inside the execute stage.** `bin/lane-checkpoint.sh` commits
   whatever the worktree is carrying as `wip: checkpoint <stage> <ISO time>` and
   pushes the branch to origin. It runs on a timer (`--watch`, every
   `CHECKPOINT_EVERY_MIN` minutes) for the length of the stage, and once more
   when the stage ends **for any reason** — clean return, rc != 0, the CC
   timeout, max-turns, or the SIGTERM of a reaped machine.
2. **Resume.** A new build of the same ticket key asks `--resume-branch` whether
   a pushed, unfinished attempt already exists. If one does, it builds **on that
   branch** and the execute prompt opens with "RESUME FROM CHECKPOINT — DO NOT
   START OVER … read `git log`/`git diff` first".
3. **Tidy before the PR.** The wip commits are squashed into one commit before
   the PR is opened, so no reviewer and no PR ever sees checkpoint noise.
4. **A checkpoint is not a build.** A branch carrying *only* checkpoints is
   still `EXECUTE_EMPTY` — it never sails into review as finished work.

Every step writes one `CHECKPOINT …` line to the build's `pipeline.log`, so the
operator can see the net working (or not working) per build:

```
2026-09-15 11:02:10Z [project-5/TK-1156] CHECKPOINT execute watcher armed — checkpointing every 15m while the stage runs
2026-09-15 11:17:11Z [project-5/TK-1156] CHECKPOINT execute committed 9 file(s) as 3f21a0c and pushed ticket/TK-1156 to origin — this tree now survives the machine
2026-09-15 11:48:02Z [project-5/TK-1156] CHECKPOINT execute-exit committed 3 file(s) as 91bd4e7 and pushed ticket/TK-1156 to origin — this tree now survives the machine
```

## The moving parts

### `bin/lane-checkpoint.sh`

```
lane-checkpoint.sh <build-dir> <worktree> <branch> [stage]   # one checkpoint
lane-checkpoint.sh --watch <build-dir> <worktree> <branch> [stage]
lane-checkpoint.sh --resume-branch <worktree> <branch> [base]
```

`project/key` for the log line come from the build dir's own `job.json`, so the
caller passes no extra arguments.

Exit codes: `0` checkpointed, a clean no-op, or switched off · `1` the commit or
push did not land (the work is local-only, and that is said out loud) · `2`
usage / not a git worktree · `4` REFUSED.

**It refuses, loudly, on four shapes.** A checkpoint runs unattended on a tree an
agent is still writing, so the refusals are where the care is:

| shape | why |
| --- | --- |
| `env/…` or a bare `*.env` in `git status --porcelain` | iron guardrail 3. `git add -A` is a blunt instrument and the one thing it must never sweep up is a credential. `.env.example` / `.sample` / `.template` are the documented exception. |
| the branch is `main` / `master` / `trunk` | a checkpoint is an unreviewed machine commit; the trunk is the one place it may never land. Both the name passed in and the branch actually checked out are tested. |
| detached HEAD | a commit there is unreachable the moment anything checks out a branch — the exact loss this exists to stop. |
| the worktree is on a different branch than the build owns | we do not guess which one is right. |

A refusal is an **ALERTS.log line, once per build dir** (LESSONS 2026-08-13,
"stopping is an alert, not a whisper"): it means this build's tree is *not*
being backed up, and a 15-minute watcher must not write twenty identical
alerts. A push that does not land alerts the same way.

`.gitignore` is respected for free (`git add` honours it). `CHECKPOINT_EXCLUDE`
(default `node_modules .next` — the same two names `run-build.sh` already passes
to `git clean -e`) covers the repo that forgot to ignore its build junk.
`--no-verify`: a repo's pre-commit hook is a minutes-long gate a backup must not
wait on and must not be failed by. The PR-time commit still runs them.

The push re-reads the GitHub token immediately before spending it
(`bin/lib/gh-token-live.sh`) and leases **explicitly** on `<branch>:<sha>` —
both for the reasons documented at `GH_LIVE`/`LEASE()` in `bin/run-build.sh`: an
App installation token lives one hour and a build runs longer, and a pool clone
is `--depth 50` single-branch so a bare `--force-with-lease` reads as "the
remote must not exist" and rejects every push after the first.

### Resume, and the invariant it leans on

`--resume-branch` answers "is there already a pushed, unfinished attempt at this
ticket?" from the **remote**, because the disk that held the last attempt is
usually gone. The signal is **wip commits at the tip**: every finished build
squashes them away before it opens its PR, so a branch that still carries them
is a lane that died on the way.

It takes the newest attempt (`ticket/x-r3` beats `ticket/x-r2` beats
`ticket/x`) and skips any branch with an **open PR** — that head belongs to the
dispatcher's `TARGET_BRANCH` fix-round path, not to resume. With no `gh` on
PATH it holds no opinion on PRs; the wip-tip invariant is the load-bearing
guard and a PR-less dead lane is the whole point.

`bin/run-build.sh` looks it up on the **unsuffixed** branch name.
`bin/blocked-resolver.sh` enqueues every rebuild with `branch_suffix=-rN`, so by
the time the pipeline gets there the branch is already `ticket/<key>-r2`, and a
lookup on that name would miss the very branch the dead lane left behind.

**Adoption heals a shallow clone first** (BH-1319). A pool warm repo is
`git clone --depth 50`, and a checkpoint branch whose fork point is older than
that boundary has no merge-base with `$BASE` at all — `git diff $BASE...HEAD`
exits 128 and the squash below refuses. So the adopt block resolves
`merge-base($BASE, origin/<branch>)` right after it decides to adopt, and when
that is empty **and** `git rev-parse --is-shallow-repository` says `true` it runs
one `git fetch --unshallow origin`, announced in `pipeline.log` before the fetch
starts and bounded by a wall-clock timeout (Config below). A complete clone and
a fork inside the boundary both pay nothing. A failed heal is logged with git's
own rc, leaves the clone shallow, and never stops the build.

Either way the resume logs the **distance**, so an operator can see which side
moved:

```
CHECKPOINT resume: merge-base 9ab9d0fb — main is 65 commit(s) past the fork, origin/ticket/TK-1156 carries 2 commit(s) on top of it
```

and a merge-base that is still unresolved after the heal says so
(`merge-base(...) UNRESOLVED — three-dot diffs against $BASE will fail and
CKPT_SQUASH_WIP will refuse`) rather than logging a distance nobody could
measure.

### Where `run-build.sh` changed

Four marked blocks, all driven by `tests/run-build-checkpoint-test.sh`:

- `# >>> checkpoint adopt` — before the "name taken on the remote, take the next
  free one" bump. A wip-tipped branch is **adopted** instead of bumped past.
- `# >>> lane checkpoints` — `CKPT_START` / `CKPT_STOP` / `CKPT_ON_EXIT`, the two
  commit counters, and `CKPT_SQUASH_WIP`. `CKPT_START` also installs TERM and
  INT handlers, because a SIGTERM'd bash does **not** run its EXIT trap unless
  the signal is trapped and a reaped machine is exactly a SIGTERM; both handlers
  save and then re-raise, so the EXIT trap still closes the job row.
- the EXIT trap gains `CKPT_ON_EXIT` as its first action — a no-op outside the
  execute stage, so a finished build never gets an extra wip commit pushed on
  top of its own PR head.
- `# >>> execute result` — `EXECUTE_EMPTY` now has two ways to be true.

A fifth block, `# >>> pre-pr squash`, wraps the last-call tidy before the pre-PR
push; it and the two refusal paths above are driven by
`tests/run-build-checkpoint.bh-1319-test.sh`.

The EXECUTE skip-guard was the subtlest change. It used to read "this branch
carries a diff, so the execute stage already ran". Since checkpoints commit
mid-stage that is no longer true, so it now also requires a **non-wip** commit,
and an adopted checkpoint branch always runs the stage again.

### Squash

`CKPT_SQUASH_WIP` soft-resets and re-commits, so **the tree is untouched by
construction** and every diff-shaped gate downstream sees byte-identical
input. It runs at the end of EXECUTE (before the spec-artifact commit, before
any review) and again, normally as a no-op, just before the pre-PR push.

**It resets onto `merge-base($BASE, HEAD)`, never onto `$BASE` itself**
(BH-1310). `$BASE` is the box's LOCAL ref for main, and a box that pulled main
fresh mid-build — the normal case on a repo merging faster than one build
takes — leaves that ref ahead of the commit the checkpoint branch actually
forked from. A soft reset never changes the TREE, but it does change the
PARENT: resetting straight onto a fresh `$BASE` re-parents the squashed
commit onto a tip that carries files the branch never saw, and every one of
those reads as DELETED in the diff a reviewer or `bin/test-tamper-scan.sh`
takes against that new parent (`TAMPER_COUNT: 433 (deleted_files=40 …)` on
TK-2937, `TAMPER_COUNT: 196 (deleted_files=20 …)` on TK-2979, both blocked
solely by this). Resolving the merge-base first, and squashing onto that,
keeps the parent exactly where the branch actually diverged. A `$BASE` the
merge-base cannot resolve against is never silently treated as the tip: the
squash fails loud (a `CHECKPOINT squash FAILED — could not resolve
merge-base(...)` line, non-zero return, wip commits left in place) rather
than guessing.

Two things it refuses to do:

- **rewrite a branch this pipeline did not cut.** A dispatcher-supplied
  `TARGET_BRANCH` is an existing PR's head (`SQUASH_OK=0`).
- **orphan an approval.** If `review-head` names anything other than the current
  head, the squash is skipped and says so — the same fail-toward-being-read rule
  the pre-PR rebase carry follows. When `review-head` *is* the head, it is
  re-bound to the new sha, exactly as the rebase does.

**A refused squash returns 1 and is recorded as the step that failed**
(BH-1319). Both FAILED paths — the unresolvable merge-base above, and a
`git reset --soft` / `git commit` that did not land — return 1, and both call
sites (the end of EXECUTE, and the last-call tidy before the pre-PR push) answer
that rc with `CKPT_SQUASH_REFUSED <execute|pr>`: one `pipeline.log` line plus a
`squash` phase row on the job, closed `failed` rc 1 with the reason the squash
gave. The build still continues with its wip commits — the refusal is now
legible instead of silent, which is the whole change. With no jobs client loaded
the phase row is skipped and the log line is the floor.

The non-wip commit messages are carried through **verbatim**:
`bin/test-tamper-scan.sh` reads `TEST-CHANGE:` justifications out of the commit
messages in range, and a squash that dropped them would turn a justified test
edit into a blocked build.

### `EXECUTE_EMPTY`, twice

| shape | RESULT |
| --- | --- |
| no diff at all vs base | `EXECUTE_EMPTY no changes produced` (unchanged) |
| a diff, but every commit is a checkpoint | `EXECUTE_EMPTY the execute session committed nothing of its own — N lane checkpoint(s) are pushed on <branch> and the next build of <key> resumes from them` |

Same prefix on purpose: every project prompt already routes `EXECUTE_EMPTY` to
one ALERTS line and no board comment, and inventing a new outcome word would
have meant editing eight prompt files to teach them one. The detail line carries
the new information — where the tree is.

### `EXECUTE_EMPTY EXECUTE_NO_PROGRESS:` — a session that writes nothing (BH-8868)

The third shape. project-6-os TK-3225 ran 3510 s with 0 file changes until its
context kill at 53.6M tokens. Now `bin/agent-call.sh`'s context meter also
fingerprints the worktree (HEAD + `git status`, minus `node_modules/`, `.next/`
and `__pycache__/`) before an execute session starts and on every poll
(`bin/lib/execute-no-progress.sh`). A new commit, an edit or a new untracked
file is progress, so a lane checkpoint is progress too. If nothing changed and
either rule fires, the meter writes `$OUT.noprogress` and stops the session:

| knob (lib `execute-no-progress`) | default | rule |
| --- | --- | --- |
| `EXECUTE_NO_WRITE_STOP_MIN` | `20` | stop after this many minutes with no change. `0` = off. |
| `EXECUTE_NO_WRITE_STOP_CEILING_PCT` | `50` | stop when the context total reaches this % of the lane's `context_kill_tokens`. `0` = off. |

Both are settings rows (`lib.execute-no-progress.<knob, lowercase>`); both `0`
turns the check off. The stop is a policy stop: rc 143, a `NO PROGRESS:` line
on `$OUT`, no model escalation, no vendor failover, cost note
`no-progress:rule=<time|ceiling>:elapsed_s=<n>`. The build ends `EXECUTE_EMPTY
EXECUTE_NO_PROGRESS: <rule> after <n>s, <total> of <ceiling> context tokens, 0
files changed` (exit 5), so the pool's relaunch cap counts it, and
`execute-transcript.md` keeps the session. The check runs only for stage
`execute`, only where the context kill runs, and a failed `git` read counts as
a change. `execute-transcript.md` now finds a killed session through
`$OUT.session` and the account's `CLAUDE_CONFIG_DIR`.

## Config

All of it is read from `env/global.env` (or a flag file), with the documented
fallback in the script header:

| knob | default | what it does |
| --- | --- | --- |
| `CHECKPOINTS` | `1` | kill switch. `0`/`off`/`false`/`no`, or `flags/lane-checkpoints-off`, makes every mode a silent no-op — the pre-2026-09-15 pipeline, byte for byte. |
| `CHECKPOINT_EVERY_MIN` | `15` | how often `--watch` checkpoints during the stage. `0` disarms the watcher (the exit-trap checkpoint still runs). |
| `CHECKPOINT_EXCLUDE` | `node_modules .next` | directories never committed even when the repo's `.gitignore` forgets them. |
| `CHECKPOINT_SQUASH` | `1` | `0` leaves the wip commits in the PR's history. |
| `CHECKPOINT_UNSHALLOW_SECS` | `900` | wall-clock bound on the one `git fetch --unshallow` an adopted checkpoint branch may trigger. |
| `CHECKPOINT_GIT_NAME` / `_EMAIL` | `harness` / `harness@localhost` | identity used only when the worktree has none configured. |

## What this is not

It is not a merge, not a deploy and not a PR. It pushes a **feature branch** —
the same object `PUSH_BRANCH` has pushed since 2026-09-11 — and nothing
downstream reacts to a branch push. The iron guardrail stands untouched: no
session here runs `gh pr merge`, pushes to main, or deploys.

It is also **never fatal to a build**. Every call site treats it as a backup,
and a backup that can fail a build is worse than no backup.

## One path, both fleets

There is only one execute path to instrument. A pool build on a Fly machine runs
`bin/run-build.sh` out of the baked image (`fly/builder-runner.sh` invokes it
with `BUILDER_EXEC=1 BUILDER_NO_MERGE=1`), and a watcher box runs the same file;
`fly/entrypoint.sh` exists precisely so that it runs **unmodified**. The only
other `agent-call.sh execute` in `fly/` is the SMOKE health probe, which has no
repo and no tree to lose. So the wiring above covers box-side and pool-side
equally, and there is no second copy to keep in step.

## Tests

- `tests/lane-checkpoint-test.sh` — the script itself, against a real git repo
  and a real bare origin: clean-but-unpushed, dirty commit+push, idempotence,
  every secret refusal, `.env.example` is not a secret, trunk, detached and
  mismatch refusals, both kill switches, the exit-trap shape, the watcher arming and
  dying with its parent, resume detection (newest attempt wins, no-wip branches
  and open-PR branches are skipped), and a dead remote reported rather than
  swallowed.
- `tests/run-build-checkpoint-test.sh` — the **wiring**, with the four blocks
  lifted verbatim out of `bin/run-build.sh`: the two counters, both kill
  switches, arm/disarm, the EXIT and TERM paths, the squash (same tree, messages
  carried, both refusals, the approval re-bind), adoption (including from an
  `-rN` rebuild), and the three `EXECUTE_EMPTY` shapes.
- `tests/run-build-checkpoint.bh-1319-test.sh` — the shallow-clone heal (a
  depth-50 clone over `file://` whose fork point is 65 commits back: adopted,
  unshallowed, merge-base restored, distance logged, then squashed onto the fork
  point), its three negatives (complete clone, resolvable merge-base, a fetch
  forced to exit 128), the rc of both FAILED squash paths, and the two call
  sites recording the refusal as a `squash` phase row — including with no jobs
  client loaded.
- `tests/rb-modules-source.bh-1319-test.sh` — `CKPT_SQUASH_WIP` and the three
  marker blocks above stay byte-identical between `bin/run-build.sh` and their
  dark twins in `bin/lib/rb/`.

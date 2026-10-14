# BH-1319: the checkpoint adopt path unshallows, both squash refusals return 1, and the callers record them

**What changed.** Three follow-ups from the review of #1317 (BH-1310), in
`bin/run-build.sh` and the three dark twins that mirror it.

1. **The adopt path heals a shallow clone before anything diffs against
   `$BASE`.** Pool warm repos are `git clone --depth 50` (`fly/Dockerfile`).
   Probed on this box (git 2.43): a checkpoint branch fetched into such a clone,
   whose fork point is older than the boundary, has **no merge-base with main at
   all** — `git merge-base main origin/ticket/x` prints nothing,
   `git diff main...HEAD` exits 128, and `CKPT_SQUASH_WIP` refuses. So the
   `# >>> checkpoint adopt` block now resolves the merge-base right after it
   decides to adopt and, when it is empty **and**
   `git rev-parse --is-shallow-repository` says `true`, runs one
   `git fetch --unshallow origin` — the conductor's `mc_unshallow_once` shape
   (`bin/lib/mc/rebase.sh`): the intent line is written BEFORE the fetch so a
   hanging remote is visible, the fetch is bounded by
   `timeout "${CHECKPOINT_UNSHALLOW_SECS:-900}"`, and a failure is logged with
   git's own rc and changes nothing else. Both outcomes then log the
   **merge-base distance** (`main is 65 commit(s) past the fork, … carries 2
   commit(s) on top of it`), or `UNRESOLVED` when there is still nothing to
   measure — the bullet #1317 asked for and did not ship.
2. **Both FAILED paths of `CKPT_SQUASH_WIP` return 1.** The unresolved-
   merge-base path already did; the `git reset --soft` / `git commit` path
   logged the same `CHECKPOINT squash FAILED` word and returned 0, so half the
   refusals were indistinguishable from success to any caller.
3. **The callers consume that rc.** All three call sites — the execute-result
   block, the pre-PR tidy, and the execute twin — become
   `CKPT_SQUASH_WIP || CKPT_SQUASH_REFUSED <execute|pr>`. The new helper writes
   one `pipeline.log` line and records the refusal as the build's failed step: a
   `squash` phase row opened and closed `failed` rc 1 with the reason the squash
   gave, using the same fail-open pattern as the e2e stage
   (`command -v job_phase_open` first, every call `>/dev/null 2>&1 || return 0`).
   **Still never fatal** — the build goes on with its wip commits, per
   `docs/CHECKPOINTS.md`. What changes is that a later `SCAN_FAILED` or
   `REVIEW_BLOCKED` reads back to a named phase instead of a deleted-file
   mystery.

The pre-PR call gained a `# >>> pre-pr squash` marker pair so a suite can drive
the real call site rather than a copy of it (D2).

**Why the twins got the identical bytes.** `CKPT_SQUASH_WIP` and the
`lane checkpoints` / `checkpoint adopt` / `execute result` blocks each exist
twice, in the driver and in `bin/lib/rb/{plan,gates,execute}.sh`, pending the
BH-478 module cutover. `tests/rb-modules-source-test.sh` case (c) pins the
FLATTEN against the driver, which — with no bare `rb_*` call in the driver yet —
is the driver against itself and cannot see a module drift. BH-1310 edited both
copies by hand with nothing checking the result.

**Verification.** `tests/run-build-checkpoint.bh-1319-test.sh` (new) cuts the
four blocks from the flatten and executes them against real git repositories
with a bare origin over `file://` so `--depth` applies: A1 a depth-50 clone
forked 65 commits back is adopted, unshallowed, its merge-base restored to the
fork sha, the distance logged, and the squash then collapses onto that fork sha;
A2 a complete clone triggers no fetch; A3 a `git` PATH shim makes
`fetch --unshallow` exit 128 and the block logs `(rc 128)`, stays shallow, logs
`UNRESOLVED` and writes no RESULT; A4 a shallow clone whose fork is inside the
boundary triggers no fetch; B1 a shim making `git commit` fail gives `rc=1` from
the second FAILED path; C1/C2 the execute and pre-PR call sites exit 0, write no
RESULT, leave the wip commits, and record `open squash … before execute|pr` +
`close 1 … could not resolve merge-base`; C3 with no jobs client the pipeline.log
line is the only artifact. `tests/rb-modules-source.bh-1319-test.sh` (new, a
registered raw reader) `cmp`s the extracted `CKPT_SQUASH_WIP` bodies and the
three marker blocks between the driver and the modules, each guarded against an
empty extraction.

All of it was red first: the plan's reproduction (`rc=1` +
`CHECKPOINT squash FAILED — could not resolve merge-base(main, HEAD)` on a
depth-50 clone) and 21 failing assertions before the change. Five mutations were
checked red afterwards — one byte of drift in `plan.sh`, the merge-base gate
removed from the heal, `job_phase_close 0` instead of `1`, the `return 1`
dropped again, and the execute call site back to a bare `CKPT_SQUASH_WIP`.

**Not done here, on purpose:** making the `bin/lib/rb/` modules live, the
pre-existing half-state left by a successful soft reset followed by a failed
commit, and `bin/test-tamper-scan.sh` (its three-dot diff is correct once the
ancestry it reads is).

Doc: CHECKPOINTS

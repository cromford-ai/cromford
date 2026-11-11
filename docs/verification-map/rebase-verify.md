# Post-rebase verify typecheck

**What it is:** the rebase stage of `bin/run-build.sh`, marked
`# >>> rebase verify` / `# <<< rebase verify`. Before the PR is opened it
fetches `origin/$BASE`, and if main (or, for a stacked build, the parent branch)
has moved it rebases the branch and re-typechecks it. The verdict rides the
RESULT line as a note, which the board close-out comment and `evidence.md`
quote, and which `bin/merge-sweep.sh` reads before it merges anything.

**The four answers it can give** (exactly one, by construction):

| RESULT note | when |
|---|---|
| *(none)* | main did not move, or the rebase typechecked green, or `origin/$BASE` did not resolve at all (no ref; a failed fetch only in `note` mode, see BH-9406 below) |
| `REBASE_VERIFY_FAILED: main moved (base=… main=…) and the rebase typechecks red` | `tsc` exited nonzero **with** `error TS…` diagnostics — a real red |
| `REBASE_VERIFY_INCONCLUSIVE: main moved (base=… main=…) but the rebase typecheck did not finish — tsc exit N …` | `tsc` crashed (exit ≥ 128 — V8 heap abort 134, SIGKILL 137), timed out (124), or exited nonzero with no diagnostics (npx could not run it). BH-575: this used to be reported as FAILED |
| `REBASE_VERIFY_INCONCLUSIVE: merge-base of origin/$BASE and HEAD is unresolvable (base=unresolved main=…)` | `origin/$BASE` resolves but shares no history with HEAD (shallow pool clone, unrelated histories). No rebase is attempted; "main moved" is never claimed without merge-base proof |
| `REBASE_CONFLICT vs origin/$BASE @sha (base=… main=…)` | the rebase itself conflicted — aborted, PR ships DIRTY |

On FAILED, INCONCLUSIVE and CONFLICT the worktree is `git reset --hard` back to
the pre-rebase head **before** the note is written, so a note never describes a
tree that was not reset.

**Fail closed (BH-9406, TK-3738).** With `rebase_verify.mode=block` (the
default; `rebase_verify.mode.<project>` is read first) two of the rows above no
longer reach a PR:

| answer | when |
|---|---|
| `BUILD_DEFERRED rebase-fetch: git fetch of origin/$BASE failed N time(s) — the branch is pushed, no PR opened` (exit 3) | the `# >>> rebase fetch (BH-9406)` block tried `rebase_verify.fetch_attempts` times (default 3, `rebase_verify.fetch_sleep_s` apart, default 10) and no fetch landed. It was `\|\| true`, so a stale `origin/$BASE` read as "main did not move" |
| `REVIEW_BLOCKED rebase-verify: conflict\|typecheck-red vs origin/$BASE (base=… main=…) after N fix round(s); see …/rebase-verify-block.txt` (exit 6) | a CONFLICT or a FAILED note, and `rebase_verify.fix_rounds` fix rounds (default 1, `rebase_verify.fix_timeout_s` each, default 1800) did not land a clean update that contains `origin/$BASE` and typechecks green. The worktree is reset to the pre-rebase head, nothing is pushed, 1 ALERTS line, 1 `escalate_block` beat |
| *(none)*, or an INCONCLUSIVE note, plus a `## Pre-PR rebase fix round` PR-body section | a fix round landed (`rebase fix round N landed` in `pipeline.log`). The fix commits sit above the reviewed head, so the head-bound gate re-reviews them |

The gate (`# >>> rebase verify gate (BH-9406)`) does nothing for an INCONCLUSIVE
note, an unresolvable merge-base, a red the baseline accepts, or a main that did
not move. `rebase_verify.mode=note` is the one-row rollback: the old fail-open
fetch and the old REBASE_CONFLICT / REBASE_VERIFY_FAILED notes. Not in this
slice: the pool reap rebase before a PR open (item 3) and the stale-build reaper
(items 4 to 7) of BH-9406.

**How an operator reaches it:** it is not its own cron lane — it runs inside
every build, after the review lenses and before the tier classification. On a
box, per build directory `builds/<project>-<KEY>-<stamp>/`:

- `pipeline.log` — `rebase typecheck at heap <N>MB (source: env|workflow|ram)`,
  then one of `rebased onto origin/main (base=… main=…) + typecheck green`,
  `… typechecked RED — reset to pre-rebase head`,
  `… typecheck INCONCLUSIVE (tsc exit 134 …) — reset to pre-rebase head, not claiming red`,
  `merge-base of origin/main and HEAD is unresolvable … — rebase skipped`, or
  `… CONFLICTED — aborted, PR ships on older base`.
- `rebase-tsc.txt` — the verify typecheck's own output, whatever it was. On a
  crash this is the FATAL line and nothing else, which is the tell.
- `RESULT` — `PR_CREATED <url>` plus the note above.
- reads `state/tsc-baseline-<project>.txt` (written by `bin/rebase-train.sh`,
  4h freshness) — a red whose every error line already exists on `origin/$BASE`
  is main's own baseline and is accepted. An INCONCLUSIVE run skips this branch:
  there are no error lines to diff.

**The heap** the verify typecheck runs at, in order: `TSC_HEAP_MB` from
`env/<project>.env` (see `env-templates/project.env.example`), else the largest
`--max-old-space-size=N` the repo's own `.github/workflows/*.yml` declare, else
70% of RAM capped at 12288. It is appended to any existing `NODE_OPTIONS`; a
later `--max-old-space-size` wins in V8.

**How to drive it:**

| what | how |
|---|---|
| the whole stage, extracted verbatim by its markers, against real `git` in a scratch repo with a fake `npx` | `bash tests/rebase-verify-test.sh` section 1 |
| the crash/red classifier (134, 137, 124, exit 1 with no diagnostics, exit 1 and exit 2 with `error TS2322`) | cases 1a-\* and 1b-\* |
| "main moved" only with merge-base proof, and the two shas in every note | cases 1s-\* |
| the heap resolver (env knob, CI-workflow declaration, RAM fallback, non-numeric knob ignored) | cases 1h-\* |
| `bin/merge-sweep.sh` parking an INCONCLUSIVE note and releasing it on a green CI Typecheck | `bash tests/rebase-verify-test.sh` section 2 |
| the approval-carry blocks nested inside this stage | `bash tests/head-bound-approval-test.sh` section 1j |
| the fetch retry and defer, the fix round, REVIEW_BLOCKED rebase-verify and `note` mode, the whole `# >>> pre-pr rebase` block run as production does | `HARNESS_TEST_SANDBOX=1 bash tests/rebase-verify.bh-9406-test.sh` (cases F1-F6, G1-G16, RT1-RT2) |

**What must never regress:**

- **An INCONCLUSIVE note never contains the substring `REBASE_VERIFY_FAILED`.**
  `bin/merge-sweep.sh` greps tokens, and the whole point is that a reader (human
  or grep) can tell a crash from a red.
- **INCONCLUSIVE parks the PR exactly as FAILED does** in `bin/merge-sweep.sh`
  (`:254`, `:264`), released by the same two paths: a head newer than the RESULT
  file, or a green CI `Typecheck` run on the head. An unverified rebase is not a
  verified one.
- **The green path is untouched.** A clean rebase that typechecks green still
  carries `review-head` across by distance (the head-bound carry block) and
  writes no note.
- **`origin/$BASE` that does not resolve changes nothing** — no rebase, no
  typecheck, no note. That was the behavior before BH-575 and it stays. A
  FETCH that fails is not that case since BH-9406: in block mode it defers.

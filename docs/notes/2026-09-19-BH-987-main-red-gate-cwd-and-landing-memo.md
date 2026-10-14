# The main-red test-only exemption no longer depends on the cwd, and a landing pass re-reads the flag

Doc: MERGE-CONDUCTOR, TEST-DETERMINISM

Two defects in `bin/lib/main-red-gate.sh`, both found by the head-bound review
of PR #957 (BH-945) at `a4017e49`, findings 1 and 2. Neither was reachable from
the suite BH-945 shipped, because both need a condition that suite never set up:
a cwd that contains test files, and two gate reads in one process.

**1. The test-only exemption was silently cwd-dependent.**
`main_red_test_path` word-splits `$MC_MAIN_RED_TEST_PATHS` (`tests/*
worker/*/test/*`) on purpose, but it did so with pathname expansion ON. From a
directory that HAS a `tests/` dir, `tests/*` expanded to the list of EXISTING
test files before the `case` ever ran, so the patterns under test were file
names, not globs. A PR whose whole diff is a NEW test file matched nothing and
was not exempt.

Which lanes that hit: the cron lanes run with cwd `/root` and had no `tests/`
to expand against, so they were accidentally correct. The tier-1 merge gate in
`bin/run-build.sh` runs after `cd "$WT"` — a repo worktree — and therefore held
every test-only PR it saw while a freeze was up, which is the opposite of the
documented exemption. It failed closed, so nothing merged that should not have.

The fix is `local -; set -f` as the first statements of the function. `local -`
restores the caller's shell options on return (bash ≥ 4.4; every box runs 5.2),
so no caller's `set` state changes — the suite asserts `noglob` still reads
`off` after the call.

**2. The landing re-ask answered from assembly time.**
`_mrg_flag_for` memoises per `(project, slug)` for the life of the process, and
it memoised the NEGATIVE answer too. `bin/merge-queue.sh` asks the gate at three
points on purpose — once while assembling a batch, then again on each landing
path — because the union fetch, merge rounds and union typecheck between them
take minutes on a real repo. With a negative memo the two landing re-asks could
only ever repeat the assembly-time answer, so a freeze raised inside that window
was invisible until the next pass. The comment above the gate claimed "a main
that goes red in that window is exactly the one that must stop the merge", which
was not true of the code under it.

The fix keeps the memo and drops it at a PASS BOUNDARY: new `main_red_forget()`
clears `MRG_MEMO_KEY`/`MRG_MEMO_VAL`/`MRG_FLAG`, and `bin/merge-queue.sh` calls
it ONCE before the train landing loop and ONCE before the serial landing
re-ask, behind the same `command -v` guard as every other gate call.

Why not "never memoise the negative": the memo exists to spend one worker GET
per pass instead of two per PR, each up to `JOBS_TIMEOUT` (8s) on an outage — a
six-entry pass would have cost 12+ `flag_sync` GETs. Forgetting once per pass
keeps that budget and still delivers the hold. A flag raised DURING a landing
pass is seen by the next pass, and the gate comment now says exactly that
instead of implying mid-pass coverage.

Clearing a POSITIVE memo is part of the same contract: a freeze that lifts
between assembly and landing now lets that pass land, which is what the next
pass would have done anyway, only sooner. No lane merges more than before except
the documented test-only exemption in the tier-1 step, which is the spec.

Callers that read once per process — the conductor tick, the tier-1 gate,
`bin/merge-sweep.sh`, `bin/review-prs.sh`, `bin/tier2-merge-sweep.sh`,
`bin/batch-resolve.sh` — neither need nor make the forget call, and are
unchanged.

**How it is driven.** `tests/main-red-gate.bh-987-test.sh`. The § E and § N
cases run the real `main_red_test_path` and the `# >>> tier-1 merge gate` block
extracted verbatim from `bin/run-build.sh` from a fixture cwd that CONTAINS
`tests/existing.sh` — the condition that hid the bug. The § L cases run the
`# >>> train landing` block verbatim with the REAL `main_red_queue_hold`, in one
process, raising the flag between the assembly read and the landing pass; § L2
pins the read budget with a counting `flag_active`; § S pins the serial path's
forget. Against the stack base the suite is 15 passed / 10 failed.

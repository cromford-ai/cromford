# BH-9879 — an owed PR close-out reaches the sweep, and a refusal keeps its reason

## The incident

project-3 TK-747 (PR #1269, 2026-11-21 08:02Z) ended `PR_CREATED` on a pool machine.
The builder posted no board close-out, and the machine and its `pipeline.log`
were destroyed at reap. The project-3 box staged the result as
`builds/project-3-TK-747-remote20261121080605/` with no `COMMENTED`. project-3 always
has a ready queue, so `bin/triage-gate.sh` step 2 always exited first: `RUN
queue-pending` (a scope with no result dirs), then `SKIP queue-unchanged` for 45
minutes. Step 3, the results sweep, never ran.

## The change

1. **The refusal keeps its reason.** The builder-direct close-out block
   (`bin/lib/rb/result.sh`, step 3) captures the rc and stderr of
   `bin/board-closeout.sh`. When it did not post a `PR_CREATED http…` or
   `PR_MERGED http…` line, it appends
   ` | CLOSEOUT-NOT-POSTED: rc=<n> <why>` (`bd_refusal_note`,
   `bin/lib/builder-direct.sh`) to RESULT line 1 and re-writes the job meta.
   The EXIT trap's `result` artifact reads line 1, so the ledger result row
   carries the reason. The note never contains `CLOSED-OUT:`, so
   `bd_closed_out` still answers no and the sweep still owns the comment.
   Other RESULT shapes, the kill flag and watcher builds are unchanged.
   Knob: `BUILDER_DIRECT_REASON_MAX` (160 chars).
2. **Step 1f of the gate.** Before step 2, `co_owed_dirs`
   (`bin/lib/closeout-owed.sh`) lists young un-COMMENTED dirs whose line 1 is
   `PR_CREATED http…` / `PR_MERGED http…` with no `CLOSED-OUT:` marker and no
   prod-red hold. If it lists one, the gate answers `RUN results-sweep` under
   step 3's own `state/<p>.sweepfp` brake. A set already bought inside the
   brake falls through to step 2. Knobs: `CLOSEOUT_OWED_WAKE` (1),
   `CLOSEOUT_OWED_MAX_AGE_S` (21600), `CLOSEOUT_OWED_BRAKE_S` (2700).

## Reading a RESULT line after this change

- `… | CLOSED-OUT: …` — the builder posted the close-out.
- `… | CLOSEOUT-NOT-POSTED: rc=<n> <why>` — the close-out ran and did not post.
- neither — the close-out block did not run (kill flag, watcher, or no
  builder exec).

Tests: `tests/closeout-not-posted.bh-9879-test.sh`,
`tests/closeout-owed-gate.bh-9879-test.sh`.

## TK-747 cause

Not known. The build machine is destroyed and its `pipeline.log` is gone. The
jobs ledger read (`job_artifact_feed result project-3`, read only) returned rc 1
with no rows on the build box, so the job row was not read. From the code, an
unmarked `PR_CREATED` RESULT comes from one of two paths:

- (a) The close-out block did not run: `BUILDER_EXEC` empty, `BUILDER_DIRECT_ON`
  not 1 (`BUILDER_DIRECT=0` or the `builder-direct-off` switch), or an empty
  RESULT.
- (b) `bin/board-closeout.sh` exited non-zero: exit 4 from the client-court
  guard (`triage-gate.sh --buildable` answered `BLOCKED …`), exit 1 (no token,
  no prod origin, comment POST refused), or exit 3 (lib missing).

After this change, case (b) leaves ` | CLOSEOUT-NOT-POSTED: rc=<n> <why>` on the
RESULT line and in the ledger. A line with no marker and no note means case (a).

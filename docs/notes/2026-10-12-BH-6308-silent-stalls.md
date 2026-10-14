# Silent stalls alert or self-clear: dead HOLDs, finished tickets kept open, hard Blocked-by on a stale parent (BH-6308)

Doc: MERGE-CONDUCTOR, OPERATING

## What happened

- #6000 kept a HOLD from 2026-10-11 11:03Z. Its owner was the Mac session
  fix-5129, which ended. Nothing built parts 2 to 5 for about 33 hours.
- #6170 delivered all of #5240 as slice C1 (merged 09:07Z). The build ran
  remote, so its record had no `plan.md`, and the PR said `Part of #5240`. The
  close guard answered `slice:no-keyword`, no open child existed, and the
  close-out posted "No child issue carries the rest yet" and kept #5240 open.
  #5241 is `Blocked-by: #5240 (hard)`, so #5241, #5242 and #5243 waited 11 hours.
- No alert fired for either stall.

## What changed

### 1. A slice close-out with no open child closes the parent

`bin/lib/slice-closeout.sh` `sco_settle` runs in `issue_slice_settle` and
`mc_close_shipped` when a complete children read finds no open child. It reads
the merged plan: `<record>/plan.md`, else `.harness/specs/<KEY>/plan.md` at the
PR's merge commit (contents API). Then it reads the plan's
`## Requirements coverage` matrix:

| Task cell | Row is |
|---|---|
| `T<n>`, `Task <n>`, `on main`, `C<j>` with j <= the merged slice | covered |
| empty, `-`, `C<j>` with j > the merged slice, later/next slice, remaining, deferred, follow-up, out of scope, not covered, not built, TODO, TBD, child | not covered |
| anything else, or `C<j>` when the merged slice is unknown | undecided |

- Every row covered: one comment with the merged slice PR links, close, strip
  `ai-build`. Word `closed-slice:closed:covered:#a,#b`.
- Every row covered, but the merged PR is a partial build (BH-5798: the
  record's `evidence.json` has a REFUTED claim, or the PR body has an
  `## Acceptance self-check` list): the matrix records the plan's intent, not
  what merged. The not-met items are the rest, and the child path below runs.
- The PR title's key names another ticket (`<KEY>` number is not N): the plan
  is not read, and the close-out answers as for no plan (`no-plan:key-mismatch`).
- A row not covered, undecided, no matrix, or no plan at the merge commit (404):
  file ONE child issue (`<KEY>.<k+1>: Rest of <KEY>: …`, `Part of #N`, the rows
  or the parent's `## Scope`, and the open issues that name `Blocked-by: #N`),
  then one comment naming the child, close, strip. Word
  `closed-slice:closed:child:#c:#a,#b`.
- The merged plan names later slices `C<k+1>..` and the record has no local
  plan (a remote build): `slice_remainder_settle` files them from the fetched
  plan (BH-5961), and the parent stays open. Word
  `kept-slice:filed:remainder-filed:#x,#y`.
- A transient read failure (a 5xx or rate limit on the PR, spec, parent or
  timeline), a held lock, a failed create or a failed close: nothing more is
  written, the word is `close-deferred:slice-closeout` rc 1, and the next
  close-out tick resumes from the ledger. A failed create pages critical
  `slice-closeout-failed:<slug>#<n>:<pr>` once.
- Switched off (`SLICE_CLOSEOUT_SETTLE=0`), a dry run, a parent closed by hand,
  or a local plan with a remainder: the path before BH-6308 runs unchanged.

The ledger is `<record>/slice-closeout/` (with no record:
`$H/state/slice-closeout/<owner>_<repo>-<n>-pr<prn>/`). `verdict`, `key`, `k`,
`rows.txt` and `children.json` are frozen once. `child`, `close-commented` and
`closed` are written only after the write they record succeeded.

`bin/lib/fc-issues.sh` takes `FC_PARENT_NOTE=0`: the filer then posts no
parent comment and leaves the parent's label alone, because the close-out
comment replaces its "This issue stays open" note.

`slice_remainder_settle` takes optional args 6-8 (plan path, key, project).
Five args behave as before.

### 2. A stale HOLD pages

`bin/pipeline-health.sh`, block `# >>> stall alerts (BH-6308)`, with the
judges in `bin/lib/stall-alerts.sh`. An open `ai-build` ticket whose newest
decisive comment is a HOLD (`hold_classify` answers `hold:comment`) older than
`STALL_HOLD_MAX_H` (12 h; `STALL_HOLD_HOTFIX_H`, 3 h, for a `hotfix` ticket)
pages `stalehold:<project>:<n>` when its owner is not active. Active means one
of: an approved participant named in the HOLD line and seen inside its online
window, a build row for the ticket that is open or newer than
`STALL_OWNER_WINDOW_H`, or an open PR of the ticket whose head commit is newer
than `STALL_OWNER_WINDOW_H`. The alert quotes the line, its author and its age,
and names RESUME as the fix.

### 3. A hard Blocked-by on a stale parent pages

The same block pages `stalledblocker:<project>:<child>:<parent>` when an open
`ai-build` ticket has a hard `Blocked-by: #P (hard)` line on an open
parent with no open child, whose newest merged slice is older than
`STALL_PARENT_MERGED_H` (3 h), with no open PR and no open build row.

Both keys are in `RETRACT_NS`. A read that fails carries the standing keys, so
a skip never retracts a page.

## Knobs

`catalog/lanes.d/_lib.stall-alerts.json` (`lane.stall-alerts.*`) and
`catalog/lanes.d/_lib.slice-closeout.json` (`lane.slice-closeout.*`). The code
fallback is the registry default.

## What this does not see

- A Mac session (fix-5129) is in no registry, so it never counts as an active
  HOLD owner. Its HOLD pages after 12 h.
- `stalehold` measures from the HOLD comment, not from the last activity on
  the thread.
- `closed:child` closes the parent, so a hard dependent's `Blocked-by: #N` is
  satisfied. The child body names those dependents; nothing rewrites their
  bodies.

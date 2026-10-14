# A decomposition's dependent children launch stacked by default (BH-3684)

Doc: BUILD-CONCURRENCY

## What changed

A decomposed ticket's siblings carry `Part of #<master>` and
`Blocked-by: #<contract> (hard)`. Once the contract child's PR opens,
`bin/unblocked-children.sh` already listed each sibling as a STACKABLE line.
That line was only an offer to a triage session. Now the harness launches it
itself, stacked on the parent's branch, with no model call.

- `bin/unblocked-children.sh` adds ` chain=#<master>` after `parent-pr=<url>`
  when the child and its one open blocker both carry the same `Part of #<master>`.
  A blocker whose body is not in the pass's issue list gets no tag.
- `bin/stack-launch.sh <project>` (NEW) filters that output. `rt_stack_filter`
  in `bin/lib/rt/scope.sh` pipes all three `unblocked-children.sh` call sites
  through it. Each STACKABLE line ends up with one of four outcomes:
  - **HELD**: `ledgers(kind=stack)` already has this child `stacked` on the
    same base, less than 6 h ago. The line is dropped and the build owns it.
  - **WAIT**: the parent PR is BLOCKed. Either its build verdict
    (`job_verdict`) is `BLOCK`, or `bin/lib/block-gate.sh:bg_scan_read` finds
    a standing BLOCK. The line is dropped and judged again next tick. This
    applies to every STACKABLE line, chain or not. `bg_scan_read`, not
    `bg_scan`, so the merge lanes' refusal streak does not move.
  - **LAUNCH**: a `chain=` line whose parent PR is open, not a draft, clear of
    BLOCKs and on the line's base. The script calls `bin/launch-fastpath.sh` in
    stack mode, and on rc 0 drops the line and writes the ledger row.
  - **PASS**: everything else prints unchanged, which is the old behaviour.
    That covers a failed read, a block state nobody could read, a fastpath
    decline, a run cap, and a STACKABLE line with no `chain=`.
- `bin/launch-fastpath.sh` has a stack mode: `FASTPATH_STACK_BASE`,
  `FASTPATH_STACK_PARENT` and optional `FASTPATH_STACK_PARENT_PR`, exactly one
  key. Condition 13 accepts the named parent as an open blocker without asking
  `dep-verify.sh`, and declines `stack parent #<n> is not an open blocker`
  when it isn't one. Every other open blocker still goes to `dep-verify.sh`.
  The spawn exports `STACK_BASE` / `STACK_PARENT_PR` to `bin/run-build.sh`
  with the same argv, and the log line reads
  `FASTPATH <KEY> (issue #n) — launched stacked on <base> (parent #<n>)`.
  HOLD, label, own-PR, ledger, lock and marker checks all still apply.

Restacking after the parent merges or closes is unchanged: the merge
conductor's `STACKED_WAIT` and restack/retarget already handle it.

## The ledger row

`ledgers(kind=stack, key="<project> <KEY>")`:

- `stacked` has `{chain, parent, parent_pr, base, depth, stacked_at,
  parent_pr_opened_at}`, plus `depth_capped:true` when the walk hit 4 levels
  or `depth_partial:true` when a read failed mid-walk. Depth 1 means the parent
  PR targets the default branch. Each hop through an open PR whose head is the
  previous base adds 1.
- `parent-merged` has the same fields plus `parent_merged_at`, `saved_s` and
  `saved_basis`. `saved_s = parent merge − stacked launch`. That is a
  **lower bound**: an unstacked child starts no earlier than its parent's merge.
- `parent-closed` means the parent closed unmerged. `saved_s:null`, no saving
  claimed.

Finalising happens once per run: at most 5 `stacked` rows from
`ledger_page stack 50`, starting at a rotating offset.

Read it with `bin/jobs-client.sh ledger-get stack "<project> <KEY>"` or
`bin/jobs-client.sh ledger-page stack 50`.

## Switches and bounds

- `stack-default-off` (settings `switch.stack-default-off`, else
  `flags/stack-default-off`) turns `bin/stack-launch.sh` into `cat`.
- `stacked-builds-off` / `STACKED_BUILDS=0` does the same, and makes fastpath
  stack mode decline `stacked builds off`.
- Per run: 5 parent PRs read, 5 launches, 5 rows finalised, a 6 h relaunch
  window, and 4 depth levels. Over a cap, the line is printed unchanged, never
  dropped.

## Log words

`logs/<project>.log`: `STACK-LAUNCH <KEY> base=<b> parent=#P pr=#N depth=<d>
chain=#C`, `STACK-WAIT <KEY> :: parent #P PR #N is BLOCKed (<build-verdict |
block-gate: <url>>)`, `STACK-HELD`, `STACK-PASS <KEY> :: <why>`,
`STACK-SAVED <KEY> depth=<d> saved=<m>m (parent #P merged)`, and
`STACK-LEDGER <KEY> :: stack row write failed (launch stands)` when the ledger
PUT after a launch fails.

Probe on the owning box:
`grep -E 'STACK-(LAUNCH|WAIT|HELD|PASS|SAVED)' /root/harness/logs/<project>.log | tail`.
The first real decomposition after deploy is the live proof. This note is
written at BUILT.

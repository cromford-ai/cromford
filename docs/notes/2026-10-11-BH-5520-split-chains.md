# Splits stop building long serial PR chains (BH-5520)

Doc: MERGE-CONDUCTOR, BUILD-CONCURRENCY

## The problem

A split ticket files its children stacked on the contract's branch. Each layer
waits for its parent's review, CI and a queue slot. At 09:07Z on 2026-10-08 the
conductor held 31 PRs in STACKED_WAIT.

## What changed

1. `bin/split-chain-report.sh [--slug S] [--days 14] [--repo PATH] [--json OUT]`
   is a new operator CLI. It measures, over a trailing window:
   - the lead time from first PR open to last merge, split against unsplit;
   - the product lines and files of each merged split child (through
     `bin/size-scope.sh --filter`) against the child's `Size budget:` line.
   It writes one JSON file with a `decision` field: `propose 1200/30`, or
   `no change: <failed condition>`. Exit 0 = report written. Exit 2 =
   `INCOMPLETE` (a GitHub read failed), and the JSON has no `decision`. Exit 1
   = usage error.
2. A decompose sibling can declare `imports_contract: false` in the spec
   (`bin/run-decompose.sh` prompt). `bin/lib/fc-issues.sh` accepts it only when
   all of these are true:
   - the value is the JSON literal `false`;
   - no `after` entry names an earlier sibling;
   - the contract's paths were extracted (`bin/planned-files.sh`);
   - the sibling's own paths were extracted;
   - no path is CONTESTED with the contract;
   - the sibling body and the contract name no common path-shaped token
     (`a/b.<ext>`, any prefix). `bin/planned-files.sh` does not keep `bin/`
     paths, so its CONTESTED list alone cannot see a shared `bin/` file. This
     check refuses one.
   A granted sibling has no `Blocked-by:` line, a soft `DEPENDS:` line on the
   contract, and the "builds on main in parallel" footer sentence. The launcher
   does not stack it. A refused sibling keeps today's hard lines and logs
   `imports_contract false refused — <check>`. The board lane
   (`bin/lib/fc-board.sh`) cannot check paths, so it always refuses and logs it.
3. `bin/lib/mc-stack-fast.sh` (merge conductor). A stacked child is retargeted
   to the project base in the same tick, and is enqueued behind its parent,
   when all of these are true:
   - the parent row is QUEUED on its reviewed head;
   - the parent's tip is in the child;
   - the child is APPROVE on its own head, CI green and not DIRTY;
   - the repo conf says `merge_method=merge`;
   - the PR is not cross-repo and the stack-merge block did not push this tick.
   Before the base PATCH, the retarget appends `Depends-On: #<parent>` to the
   child's body. Mergify then holds the child at the merge step until the
   parent has merged, so a parent that Mergify dequeues between two conductor
   ticks (for example on a REQUEST_CHANGES review) cannot merge under the
   child. A body that cannot be read or written means no retarget.
   The retarget writes a mark in
   `state/merge-conductor/stack-fast/<owner>__<repo>#<num>` only after the
   PATCH answers rc 0, and logs `STACK_FAST`. Each tick re-reads the parent of
   a marked child. A merged parent drops the mark. A parent that left the
   queue unmerged starts a revoke: an attempt line, label off,
   `@mergifyio dequeue` with the conductor's tag, and a PATCH back onto the
   parent's branch, logged `STACK_FAST_REVOKED`. The revoke is the cleanup;
   the Depends-On line is the guard. A head that was revoked once
   is not fast-tracked again.

## Knobs

- `MC_STACK_FAST` (default 1). Set 0 to restore the pre-BH-5520 wait.
- `MC_STACK_FAST_MARK_TTL_S` (default 604800). `msf_sweep` drops older marks.
- Both are in `catalog/lanes.d/_lib.mc-stack-fast.json`.

## Not changed

- The fleet size rows stay 700/20. `bin/split-chain-report.sh --days 14`
  ran on 2026-10-11 at 14:25Z with exit 0. (Until the fix for the lead BLOCK
  on 95d38af8, that command exited 1 with no `--slug`, so this run must have
  named the slug. The read was capped (`capped: true`): child issues older
  than the cap read as unsplit, which shifts both medians.)
  - split tickets: n=82, median lead 30.9h, p75 64.1h;
  - unsplit tickets: n=243, median lead 4h, p75 16.9h;
  - merged split children: n=350 (6 unmeasured), product lines p50 217,
    p75 352, p90 578; product files p75 6, p90 10;
  - 2300 PRs and 3000 issues read (`capped: true`);
  - `decision: propose 1200/30`.
  The plan moved the rows with a guarded `UPDATE` in `worker/jobs/schema.d/`.
  `tests/schema-additive.bh-1000-test.sh` forbids that: `schema.sql` holds only
  `CREATE ... IF NOT EXISTS` and `INSERT OR IGNORE`, because harness-sync
  re-sends statements. No other mechanism moves an actor `seed` row. Issue
  #6025 carries the numbers and the decision the operator must make.
- A split whose contract names no extractable path (for example only `bin/`
  files) has no contract paths, and every sibling is refused independence.
  That is fail-closed. A contract that names `bin/` and `tests/` paths is
  checked by the token check in item 2.

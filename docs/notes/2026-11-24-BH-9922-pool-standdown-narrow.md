# BH-9922: the pool names the collision, stacks on a green queued blocker, and drops the row of an archived ticket

Doc: FLY-POOL, BUILD-CONCURRENCY

## Cause

On 2026-11-23, on project-3:

- At 18:16-18:22Z the plans of TK-815, TK-826, TK-827, TK-828, TK-832,
  TK-836 and TK-840 each stood down with `DEFERRED TK-xxx: waits for TK-797
  (stand-down 2)`. Each stand-down cost a plan machine of 7 to 11 minutes.
- Until 20:01Z each tick said `skipping TK-xxx: waits for TK-797`. The pool
  said `under-used for 100m: queued 9, building 3 of capacity 12`.
- TK-797 (PR #1326) changes 11 files. The 7 waiting tickets are about other
  areas. No line named the shared file. `prisma/schema.prisma` and
  `docs/DATABASE.md` are the probable ones.
- At 20:01Z the pool said `RELEASED TK-810: TK-776 is done` and spawned
  machine 0803426fd77048. The owner archived TK-810 on the board at 15:20Z.
  `pool_hold_check` answers `clear board ticket` with no read, and the
  release read nothing either.

## What changed

1. The stand-down names its collision.
   - `bin/plan-overlap.sh` and `bin/plan-sibling.sh inflight` append
     ` symbols=[model:X,..]` (a kept schema pair) and ` more=<n>` (real pairs
     past the 3 the line carries) after `files=[..]`. The four prefix readers
     (plan-after.sh, plan-sibling.sh note, defer-after-stop.sh,
     defer-report.sh) still match.
   - `defer_after_on` (bin/lib/deferral-after.sh) makes the label: symbols,
     then files, first 3, then ` (+N more)`.
   - The pool reap keeps it as `after_on` in the queue meta and the queue
     file. The DEFERRED line and each `skipping <KEY>: waits for <O>` line
     end `; collides on <label>`.
2. An additive shared file alone does not serialize
   (bin/lib/additive-overlap.sh).
   - The list is the knob `PLAN_OVERLAP_ADDITIVE_FILES` (lib plan-hotspot,
     per-project settings row). Default: `prisma/schema.prisma
     docs/DATABASE.md docs/API.md changelog.d/ .changeset/ docs/changes/`.
     `off` turns the rule off. An entry that ends in `/` is a directory.
   - A non-schema entry on both sides is safe.
   - `prisma/schema.prisma` is safe when the two sides touch no common
     `model|enum|type|view` block and neither side edits a `datasource` or
     `generator` block. The candidate side is the blocks its plan.md names.
     The other side is its plan.md on this host (plan-overlap) or the open
     PR's patch (plan-sibling inflight, cached at
     `state/plan-inflight/<p>/<pr>.<sha>.models`, 7-day delete on write).
     A side that cannot be read keeps the collision.
3. A row whose blocker PR is open, green on every check run and in the merge
   queue is released onto a stack base of that PR's head
   (bin/lib/after-stack.sh `as_pr_ready`, knob `POOL_AFTER_STACK_QUEUED`,
   default 1).
   - The line is `RELEASED <KEY>: stack: <O>'s PR #<n> is green and in the
     merge queue (stack_base <ref>)`.
   - The release writes `stack_base` in the requeue meta and the queue file,
     and `defer-after.released` in the key's newest record
     (`dfs_mark_released`), so `dfs_stop_check` does not hold it again.
   - On the machine, `sw_pre` (bin/lib/stack-wait.sh) answers `queued <pr>`
     for the same parent, and the stack plan gate in bin/lib/rb/gates.sh
     stacks with no `stack-wait-pending` file.
4. The pool reads the board ticket before a release, and before a spawn of a
   row whose `.enqueued_at` is at least `POOL_TICKET_LIVE_AGE_S` old
   (default 21600 s; 0 = before every spawn).
   - `ptl_read` (bin/lib/pool-ticket-live.sh) reads through the tracker
     board seam. Only in-app board tickets are read.
   - An archived, done, paused or not-found ticket: the row is FAILED with
     `ticket <id> is <class> on the board — pool row dropped, no machine`,
     the queue file is removed, the hold marker is cleared, and the pool says
     `DROPPED <KEY>: ...`.
   - A 404 is `not-found` only when the `/boards` read answers 2xx in the same
     call. Any read that does not answer is `unreadable`: one line, and the
     row goes on as before.

## Knobs

| Knob | Owner | Default | Off |
|---|---|---|---|
| `PLAN_OVERLAP_ADDITIVE_FILES` | lib plan-hotspot | the list above | `off` |
| `POOL_AFTER_STACK_QUEUED` | fly-pool | 1 | 0 |
| `POOL_TICKET_LIVE_AGE_S` | fly-pool | 21600 | (0 = read before every spawn) |

## Tests

- `tests/plan-overlap-additive.bh-9922-test.sh`: the additive rule, the two
  overlap scripts, the `.models` cache.
- `tests/pool-standdown-narrow.bh-9922-test.sh`: the pool tick, with the
  2026-11-23 project-3 queue as the fixture (`tests/fixtures/bh-9922-project-3/`).

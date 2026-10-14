# The hub half of REBASE_ON_POOL: enqueue, the `pool` job state, apply

Doc: MERGE-CONDUCTOR

**What changed.** The two `mc_pool_rebase_*` stubs #540 shipped now have bodies,
and the conductor and the resolver read the rcs they answer.

- `mc_pool_rebase_enqueue` writes the job file first, under the existing
  `state/merge-conductor/rebase/.lock`, then one `queue_put` row keyed
  `RB-<num>-<head8>` (`ticket_id` = the PR number, `target` = fly, meta =
  `{kind,slug,url,pr,branch,head,base}` and nothing else). It then clears this
  head's `rebasedone`/`rebasefailed` attempt lines and writes a `queued` jobs
  ledger row. rc 6. A queue that refuses removes the job file and answers rc 7
  with nothing recorded anywhere.
- `mc_rb_state` learned `status:"pool"`: running on its age alone until
  `started_at + MC_REBASE_POOL_TIMEOUT_SECS` (default 5400), then stale.
  `mc_lane_state` is untouched, so the re-review and deploy-verify lanes keep
  the pid rule exactly.
- `mc_pool_rebase_apply` reads a machine's RESULT into that job file. The KEY
  wins over the file: the `PR:` line is used only when it names the key's
  number, the `HEAD:` line only when it is 40 lowercase hex starting with the
  key's head8. Anything unparseable records rc 4, never 0, and rc 0 happens only
  when `job_verdict_rebind` answered 0 — otherwise rc 5 and the approval stays
  where it was.
- `bin/merge-conductor.sh`: `rebase_result` gained arms 6 (REBASING, "pool
  rebase queued") and 7 (NEEDS_REBASE, "pool queue unreachable, retry"); the
  `NEEDS_REBASE` arm takes the inline path under the flag and spawns nothing;
  `rebase_consume` writes a `TIMED_OUT` ledger row when a `pool` job runs out of
  clock, and still reads a RESULT that lands after that.
- `bin/blocked-resolver.sh`: `br_mechanical` arm 6 counts the rung and moves the
  conductor row to REBASING; arm 7 spends nothing.

**Why.** A rebase costs the hub a clone, a worktree, a typecheck and a unit run,
all of it serial on the one box that also runs every tick. Under the flag that
work moves to a pool machine and the hub keeps the lease, the approval rebind
and the merge. The key-vs-RESULT cross-check exists because the RESULT is a text
file written somewhere we do not control: without it a `PR:` line naming another
PR would rebind that PR's approval, and a `HEAD:` line could become a path
component.

**What it touches.**

- State: `state/merge-conductor/rebase/<owner_repo>_<num>_<head>.json` gains a
  `pool` status and is written by the enqueue as well as by the lane;
  `state/merge-conductor/attempts.txt` keeps one `rebase <key> <head>` line per
  enqueued head and loses its `rebasedone`/`rebasefailed` line on every
  successful enqueue.
- Knobs: `REBASE_ON_POOL` (per project, ships OFF) and
  `MC_REBASE_POOL_TIMEOUT_SECS` (default 5400). `MC_REBASE_PARALLEL` now counts
  pool jobs as running; it defaults to 0 (unlimited) fleet-wide, so no default
  behaviour changes.
- Log lines: `pool rebase queued as RB-…`, `pool rebase running on a pool
  machine`, `produced no RESULT within …s`, `RESULT for RB-… names PR x, not y —
  ignored`, and the resolver's `MECHANICAL — pool rebase queued for …`.
- `bin/rebase-train-ahead.sh` gets rc 6/7 through `mc_rebase` and has no arm for
  them: they fall into its existing non-zero case, nothing is pushed and nothing
  is spent. No code change there, by design — the ticket names three files.

**Still owed.** The flag must stay unset fleet-wide until BH-486.3 lands:
`bin/fly-pool.sh` does not yet read `meta.kind=rebase`, so a row queued today
would be claimed as a ticket build. The live proof — flag on for one project,
one real DIRTY PR, a RESULT from a machine, hub `tmp/` flat — is owed after
BH-486.3 and BH-486.4 merge. Everything here is proven by
`tests/rebase-on-pool-test.sh` and `tests/blocked-resolver.bh-541-test.sh`,
which drive the real scripts against a scratch harness.

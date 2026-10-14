# A reaped `RB-` stand-down fails the hub job file, and the ALERTS line stops overstating recovery

Doc: MERGE-CONDUCTOR

**What was wrong.** Both `RB-*` arms of `bin/fly-pool.sh` — the `BUILD_DEFERRED`
arm and the dead-machine arm — closed the queue row `failed` and then wrote an
ALERTS line saying `bin/merge-conductor.sh re-enqueues the rebase on its next
tick if the PR still needs one`. It does not. The arms never touched the hub job
file `state/merge-conductor/rebase/<owner_repo>_<num>_<head>.json`, which stayed
at `status: pool`; `mc_rb_state` reads a `pool` file as `running` on its age
alone until `started_at + MC_REBASE_POOL_TIMEOUT_SECS` (5400s), so the conductor
held the PR in `REBASING` for up to 90 minutes before `rebase_consume`'s
`failed|stale` arm parked it in `NEEDS_REBASE`. An operator reading that line
walked away from a PR that was stalled. `docs/verification-map/rebase-on-pool.md`
repeated the claim at the transport section, and its closing paragraph still
called `mc_pool_rebase_enqueue` and `mc_pool_rebase_apply` stubs long after both
grew real bodies.

**What changed.**

- **NEW `mc_pool_rebase_fail <project> <key> [reason]`** in
  `bin/lib/merge-conductor-lib.sh`, next to `mc_pool_rebase_apply`. It parses
  `RB-<num>-<head8>`, globs `$MC_RB_DIR/*_<num>_<head8>*.json` (the exact
  fallback lookup the apply already uses — the machine json carries no `rebase`
  object, so the key is all there is), and for each file whose `status` is `pool`
  calls `mc_rb_fail` under the existing `$MC_RB_DIR/.lock` flock. rc 0 = at least
  one file marked `failed` with `rc: 4`, `head_sha` and `started_at` preserved;
  rc 1 = not an `RB-` key, no file, or every file already `done`/`failed`. It
  also writes a `job_ledger_put rebase "<url>@<head>" FAILED` row when the jobs
  client is sourced, mirroring the `TIMED_OUT` row the conductor's timeout arm
  writes on the same key.
- **Both `RB-*` arms of `bin/fly-pool.sh`** call it behind `command -v` (the lib
  is soft-sourced, and a half-synced box must not read a missing function as
  success), then pick one of two honest ALERTS sentences from its rc: job file
  failed → the conductor parks the PR in `NEEDS_REBASE` on its next tick and the
  `NEEDS_REBASE` TTL (`MC_TTL_NEEDS_REBASE`, default 1800s) is what allows a
  fresh rebase; nothing marked → recovery waits for
  `MC_REBASE_POOL_TIMEOUT_SECS` (5400s) first, then the same TTL. Still exactly
  ONE ALERTS line per event, and the block comments that repeated the old claim
  were corrected in the same commit.
- **The deferred arm's queue-row reason is now a constant** —
  `rebase machine stood down before the job ran; row FAILED, not requeued`. The
  `DROW` sed that spliced the runner's RESULT text into the ledger row is gone;
  that text still rides in the ALERTS line, the `say` line and the build dir.
  The reason still matches neither `died N times` nor `deferred N times`, so
  `br_from_queue` cannot read it as a rebuild trigger for ticket `<pr>`.

**A `done` file is never rewritten.** A late machine RESULT is a fact: the apply
already recorded what the rebase did, possibly including a pushed sha and a
rebound approval, and stamping `failed` over it would hide that from every
reader. Only a `pool` file — the one this reap is the last word on — is touched.

**What it deliberately does not do.** Marking the job file `failed` does NOT
clear the `rebase <key> <head>` attempt marker or remove the file, so the
`NEEDS_REBASE` TTL still gates a fresh rebase of this head. Clearing them would
let the conductor queue on the very next tick and hand a flapping pool an
unbounded rebase loop on one head; the TTL stays the pacing, and the ALERTS text
says so rather than implying otherwise.

**What it touches.** State: an existing rebase job file flips `pool` → `failed`
(`rc: 4`). Knobs: none new; the text names `MC_REBASE_POOL_TIMEOUT_SECS` and the
`NEEDS_REBASE` TTL, neither changed. Log lines: `merge-conductor.log` gains one
`pool rebase marked failed on the hub` / `no pool job file` line per call, and
the two `RB-` ALERTS lines carry new tails. Downstream: `rebase_consume`'s
failed/stale arm is reached one tick after the reap instead of 90 minutes later,
and a `failed` file no longer counts as running in `mc_rb_running`. No non-`RB-`
key changes behaviour.

**How it is proven.** `tests/rebase-on-pool-reap.bh-986-test.sh` drives
`bin/fly-pool.sh` whole against the real lib (job file JSON, ALERTS text, the
queue PATCH body from the curl sink), the unit section drives the real
`mc_pool_rebase_fail` in process, and one section runs both arms against a
fixture lib that does NOT define the function so the second sentence is exercised
too. Five mutations were checked red: dropping the call from either arm, putting
the old next-tick text back, restoring `$DROW`, and letting the function rewrite
a `done` file.

# shellcheck shell=bash
# bin/merge-conductor.d/bh-9243-restamp-rebase.sh - A STALE SCHEMA STAMP GETS
# ITS REBASE IN THE SAME TICK (BH-9243). Sourced by bin/merge-conductor.sh (the
# BH-7453 fragment block); no side effect at source time.
#
# THE DEFECT. pq_gate answers `rebase` for a reviewed head with a stale schema
# stamp (deferred-land, BH-9154). The conductor wrote NEEDS_REBASE and
# returned. The next tick the classifier wrote READY again ("clean, approved,
# checks green") before the NEEDS_REBASE arm ran, and that arm's merge-tree
# test leaves a clean head alone anyway: a stale stamp is not a conflict. #9140
# made 22 READY/NEEDS_REBASE transitions in one day with no rebase.
#
# mc_pq_restamp_rebase — pr_worker calls it in the READY arm when pq_gate
# answers `rebase` with PQ_RESTAMP_LAND=1, with P SLUG NUM KEY HEAD BR URL REC
# REVIEWED VERDICT MSTATE RAWLBL PROVIDER MERGES in scope.
#   rc 0  it acted, and pr_worker returns: the rebase spawned (REBASING), or
#         it could not spawn this tick and the row stays READY with a
#         `prequeue-restamp` ready-why. Never a NEEDS_REBASE transition, so no
#         READY/NEEDS_REBASE flap is possible without a push.
#   rc 1  not this function's case: pr_worker writes NEEDS_REBASE as before.
#         A conflict `rebase` (PQ_RESTAMP_LAND=0), the kill switch, pool mode.
#
# The rebase is mc_rebase, whose push carries the restamp (mc_rebase_restamp).
# Bounded like the eject arm (eject_rebase_arm, bin/lib/mc/rebase.sh): once
# per (PR, head) by the `pqrestamp <key> <head>` mark, and by the
# MC_LAND_REBASE_PARALLEL hub cap. MARK FIRST (D16): the mark is written before
# the spawn and cleared when nothing was spent, so the next tick asks again.
# The ordinary `rebase <key> <head>` mark is written after a spawn.
#
# Knob: MC_PQ_RESTAMP_REBASE (env, default 1). 0 restores today's NEEDS_REBASE
# line exactly. Pool mode: the BH-9154 hook holds a reviewed stale head there
# (REBASE_ON_POOL), so this path is a defence only and answers rc 1.
# Tests: tests/mc-dequeued-restamp.bh-9243-test.sh.
mc_pq_restamp_rebase() {
  [ "${MC_PQ_RESTAMP_REBASE:-1}" != 0 ] || return 1
  [ "${PQ_RESTAMP_LAND:-0}" = 1 ] || return 1
  if command -v mc_pool_rebase_enabled >/dev/null 2>&1 && mc_pool_rebase_enabled "$P"; then return 1; fi
  local erc why="stale schema stamp on ${HEAD:0:8}"
  # Another lane owns the PR (a live Mergify hold, a migration apply lane), or
  # a read failed: no rebase this tick. The gate logs its own line.
  if ! mc_rebase_gate restamp; then
    mc_ready_why "$KEY" "$HEAD" prequeue-restamp "$why: the restamp rebase waits (${MC_RBG_WHY:-gate}); asked next tick"
    return 0
  fi
  if mc_attempt_has "pqrestamp $KEY $HEAD" 2>/dev/null || mc_attempt_has "rebase $KEY $HEAD" 2>/dev/null; then
    mc_ready_why "$KEY" "$HEAD" prequeue-restamp "$why: this head already had its restamp rebase; its result moves the head"
    return 0
  fi
  if [ "${MERGES:-0}" != 1 ]; then
    mc_log "$KEY would PQ_RESTAMP_REBASE $HEAD (merge mode off) — $why"
    mc_ready_why "$KEY" "$HEAD" prequeue-restamp "$why: merge mode off, no restamp rebase" logged
    return 0
  fi
  mc_attempt_put "pqrestamp $KEY $HEAD"
  # A new rebase job for this head; the pqrestamp mark dedupes it (BH-2358).
  mc_attempt_clear rbjob "$KEY" "$HEAD done"
  mc_rebase_spawn "$SLUG" "$NUM" "$P" "$BR" "$HEAD" "$URL" "${MC_LAND_REBASE_PARALLEL:-4}"; erc=$?
  if [ "$erc" != 0 ]; then
    mc_attempt_clear pqrestamp "$KEY" "$HEAD"
    mc_ready_why "$KEY" "$HEAD" prequeue-restamp "$why: restamp rebase not spawned — $(mc_rebase_spawn_why "$erc") (rc $erc, MC_LAND_REBASE_PARALLEL=${MC_LAND_REBASE_PARALLEL:-4}); asked next tick"
    return 0
  fi
  mc_attempt_put "rebase $KEY $HEAD"; mc_count_inc "$P" rebases >/dev/null
  mc_log "PQ_RESTAMP_REBASE_SPAWNED $KEY $HEAD — detached rebase of ${HEAD:0:8} into $BR; its push restamps the stale schema stamp ($(mc_rebase_job_ref "$SLUG" "$NUM" "$P" "$HEAD"))"
  mc_transition "$KEY" REBASING "REBASING ${HEAD:0:8} (restamp rebase: stale schema stamp)" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
  return 0
}

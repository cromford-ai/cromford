#!/bin/bash
# shellcheck shell=bash
# module: worker
# bin/lib/lead-review/worker.sh — the review pool worker: its exit cleanup,
# result tally, entry, lead-land ring and free-slot test. Sourced by
# bin/lead-review.sh through bin/lib/lead-review/load.sh, never run. Defines
# functions only. Reads the host's WT, BEAT, LRBEAT, LR_KEYFD, REPO_DIR, QF, R,
# LR_RING*, RPOOL_K and RPOOL_TMP_OWN; adds to the tick's result counters.

cleanup() {
  [ -n "$BEAT" ] && job_beat_stop "$BEAT"; BEAT=""
  [ -n "$LRBEAT" ] && job_beat_stop "$LRBEAT"; LRBEAT=""
  [ -n "$LR_KEYFD" ] && exec 8>&-; LR_KEYFD=""
  if [ -n "$WT" ]; then
    git -C "$REPO_DIR" worktree remove --force "$WT" >/dev/null 2>&1
    rm -rf "$WT" "$WT".*; git -C "$REPO_DIR" worktree prune >/dev/null 2>&1; WT=""
  fi
}

rpool_on_result() {
  case "$2" in
    done) done_n=$((done_n + 1)) ;; superseded) superseded=$((superseded + 1)) ;;
    failed|killed) failed=$((failed + 1)) ;; stop) stopped=worker ;;
    paid) paid=$((paid + 1)) ;; replayed) replayed=$((replayed + 1)) ;; capped) capped=$((capped + 1)) ;;
    ratelimited) ratelimited=$((${ratelimited:-0} + 1)); rpool_rate_hit ;; *) skipped=$((skipped + 1)) ;;
  esac
  [ "$2" = done ] && rpool_rate_ok
  return 0
}
# The worker's clock starts at its own start: a review started late in the tick
# gets the same budget a tick's first review always had, never a shorter one.
lr_worker() {
  SECONDS=0; RPOOL_ON_EXIT=lr_worker_exit
  # The rules pack builds its nobody-reachable snapshot here, not in the shared
  # /tmp, so it goes with the worker on every exit path (RPOOL_TMP_PREFIX below).
  [ -n "$RPOOL_TMP_OWN" ] && export RULES_PACK_SNAPSHOT_TMP="$RPOOL_TMP_OWN"
  LR_RING=0 LR_RING_REPO="" LR_RING_PR="" LR_RING_SHA="" LR_RING_REPORT="" LR_RING_RP=""
  review_one "$1" "$2" "${3:-full}"
}
# lr_ring_land — in the worker's exit trap, so it runs before the tick collects
# the result, and on TERM too. Rings only after a delivered terminal result.
lr_ring_land() {
  local rp sha12 rc
  [ "$LR_RING" = 1 ] || return 0
  sha12="${LR_RING_SHA:0:12}"
  rp="$LR_RING_RP"
  [ -z "$rp" ] && [ -n "$LR_RING_REPORT" ] && rp=$(sed -n 's/^- rules pack: //p' "$LR_RING_REPORT" 2>/dev/null | head -n 1)
  case "$rp" in
    "could not run"*)
      log "lead-land doorbell withheld for $LR_RING_REPO#$LR_RING_PR@$sha12 (rules pack could not run); the */15 cron covers it"
      return 0 ;;
  esac
  if ! command -v lcw_ring >/dev/null 2>&1; then
    log "lead-land doorbell not rung for $LR_RING_REPO#$LR_RING_PR (lib missing); the */15 cron covers it"; return 0
  fi
  # In a subshell: this runs inside the worker's EXIT trap, where a bare
  # `return` (as _lcw_off's) answers the status from before the trap, so the
  # kill switch read as ON every time.
  ( lcw_ring lead-land "$LR_RING_REPO" "$LR_RING_PR" "$LR_RING_SHA" ); rc=$?
  if [ "$rc" -eq 0 ]; then
    log "lead-land doorbell rung for $LR_RING_REPO#$LR_RING_PR@$sha12"
    echo x >> "$QF.rung"
  else
    log "lead-land doorbell not rung for $LR_RING_REPO#$LR_RING_PR (rc $rc); the */15 cron covers it"
  fi
  return 0
}
lr_worker_exit() { cleanup; lr_ring_land; RPOOL_RESULT="$R"; }
# A free slot counts every live worker on the box: a tick that released its
# lock may still run some (BH-6984).
lr_slot_free() {
  local r; r=$(rpool_box_running)
  [ "$r" -lt "$RPOOL_K" ] && lw_concurrency_ok "$r"
}

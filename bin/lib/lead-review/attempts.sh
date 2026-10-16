#!/bin/bash
# shellcheck shell=bash
# module: attempts
# bin/lib/lead-review/attempts.sh — counted failures on a head, the
# release marker and the rate-limit release. Sourced by bin/lead-review.sh
# through bin/lib/lead-review/load.sh, never run. Defines functions only.
# Reads the host's LR_RING_REPO, LR_RING_PR, LR_RING_SHA and LR_RING; sets R.

# lr_count_fail <id> <job> <sha> <reason> — one COUNTED failure on this head
#   (header): the pr_attempts row lead-review-<n>. rc 0 = it was the third, and
#   outcome=failed detail="attempts-exhausted: <reason>" was delivered (the job
#   is failed) and the gate fact review_failed_sha written. rc 1 = not terminal:
#   counted below 3, or the count could not be read or written (logged, never
#   read as a success); the caller fails the job or leaves it as before.
lr_count_fail() {
  local n where="$LR_RING_REPO#$LR_RING_PR@${3:0:12}"
  n=$(lw_attempts "$LR_RING_REPO" "$LR_RING_PR" "$3") || { log "attempts on $where unreadable; '$4' not counted"; return 1; }
  n=$((n + 1))
  lw_attempt_add "$LR_RING_REPO" "$LR_RING_PR" "$3" "$n" || { log "attempt $n on $where ($4) not recorded"; return 1; }
  log "counted attempt $n of 3 on $where: $4"
  [ "$n" -ge 3 ] || return 1
  fail_terminal "$1" "$2" "$3" "attempts-exhausted: $4"
  [ "$LR_RING" = 1 ] || { log "attempts exhausted on $where but the failed result was not delivered"; return 1; }
  pr_gate_event_put "$LR_RING_REPO" "$LR_RING_PR" "lead-review-failed@${3:0:12}" lead-review:failed "review_failed_sha=$3" >/dev/null 2>&1 \
    || log "review_failed_sha for $where not recorded"
  log "failed $where: attempts-exhausted: $4"; R=failed
  return 0
}

# lr_left_running <why> — this worker ends on purpose and leaves its request row
#   `running`: the release marker (lw_release) tells the next tick that takes the
#   claim over that it is not a crashed claim, so the takeover is not counted.
#   A marker that cannot be written is logged: that takeover then counts.
lr_left_running() {
  lw_release "$LR_RING_REPO" "$LR_RING_PR" "$LR_RING_SHA" \
    || log "release marker for $LR_RING_REPO#$LR_RING_PR@${LR_RING_SHA:0:12} ($1) not written; the next takeover counts"
}

# lr_fail_counted <id> <job> <sha> <reason> [open] — a counted failure that ENDS
#   this worker: lr_count_fail, and when it is not terminal, the release marker
#   (the failure is counted once, never again as a takeover) and the job failed,
#   or with `open` left for the watchdog.
lr_fail_counted() {
  lr_count_fail "$1" "$2" "$3" "$4" && return 0
  lr_left_running "$4"
  [ "${5:-}" = open ] || job_update "$2" status=failed
  return 1
}

# BH-5284: an agent call refused for a rate or concurrency limit (a 429,
# "overloaded", the account's concurrency cap) bought no review. It records no
# verdict, writes no .empty and posts no result: the job fails and the request
# is left for a later tick, exactly as a before-billing refusal (rc 74..79) is.
# R=ratelimited tells the tick to pause new starts (rpool_rate_hit, for
# LEAD_REVIEW_RATE_BACKOFF_S, doubling to 900s); it is never counted as a
# failed review.
lr_rate_limited() { [ "$1" -ne 0 ] && command -v rpool_rate_limited >/dev/null 2>&1 && rpool_rate_limited "$2"; }
lr_release_rl() { # lr_release_rl <key> <job> <rc>
  log "agent call for $1 hit a rate or concurrency limit (rc=$3); no verdict recorded, request left for a later tick"
  lr_left_running "rate limited"
  job_update "$2" status=failed; R=ratelimited
}

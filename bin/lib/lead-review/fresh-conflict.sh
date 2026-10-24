#!/bin/bash
# shellcheck shell=bash
# module: fresh-conflict
# bin/lib/lead-review/fresh-conflict.sh — the fresh conflict hold. After the
# lead review fetches origin/<base>, a head that conflicts with it is ended
# superseded, with no verdict and no agent call: main rewrote what the head
# changes, so a review could only buy a BLOCK the PR did not cause, and the head
# must change before it can merge anyway. The conductor's rebase or a fix round
# makes the new head, which gets an ordinary review. The request-time holds
# (bin/lib/lead-gates.d/85-rebase-hold.sh) read the clone before this fetch.
# Sourced by bin/lead-review.sh through bin/lib/lead-review/load.sh, never run.
# Defines functions only. Reads LEAD_REVIEW_FRESH_CONFLICT_HOLD (catalog knob,
# default 1, 0 = off) and the host's post_result, job_update and log; sets
# LR_FC_WHY and R.

# _lr_fresh_lane_request <request-json> — rc 0 for the lane's own request: the
# enqueue (requested_by lead-review-enqueue:*) or a worklist item
# (requested_by lead-review-worklist, or src worklist). Any other row is a
# review a person asked for, so it is reviewed: the patch-same replay rule.
_lr_fresh_lane_request() {
  local rby rsrc
  rby=$(jq -r '.requested_by // ""' <<<"$1" 2>/dev/null); rsrc=$(jq -r '.src // ""' <<<"$1" 2>/dev/null)
  [[ "$rby" == lead-review-enqueue:* ]] || [ "$rby" = lead-review-worklist ] || [ "$rsrc" = worklist ]
}

# lr_fresh_applies <request-json> — rc 0 when the hold is on and the request is
# the lane's own. A knob value other than 0 or 1 is logged once and read as 1.
_LR_FC_BAD_LOGGED=""
lr_fresh_applies() {
  local k="${LEAD_REVIEW_FRESH_CONFLICT_HOLD:-1}"
  case "$k" in
    0) return 1 ;;
    1) ;;
    *) [ -n "$_LR_FC_BAD_LOGGED" ] || log "LEAD_REVIEW_FRESH_CONFLICT_HOLD='$k' is not 0|1; the fresh conflict hold is on"
       _LR_FC_BAD_LOGGED=1 ;;
  esac
  _lr_fresh_lane_request "$1" || return 1
}

# lr_fresh_conflict <clone> <base> <sha> — rc 0 when a 3-way merge of
# origin/<base> and <sha> conflicts; LR_FC_WHY names up to 5 conflicted paths
# (display text, the same cut as the enqueue's RBWHY). rc 1 for a clean merge
# and for anything that cannot run (no origin/<base>, no head object, a
# merge-tree rc other than 0 or 1): fail-open, the head is reviewed.
lr_fresh_conflict() {
  local out mrc n paths
  LR_FC_WHY=""
  git -C "$1" cat-file -e "$3^{commit}" 2>/dev/null || return 1
  git -C "$1" rev-parse -q --verify "origin/$2^{commit}" >/dev/null 2>&1 || return 1
  out=$(git -C "$1" merge-tree --write-tree --name-only --no-messages "origin/$2" "$3" 2>/dev/null); mrc=$?
  [ "$mrc" = 1 ] || return 1
  paths=$(printf '%s\n' "$out" | sed 1d | grep . | LC_ALL=C sort -u)
  n=$(grep -c . <<<"$paths")
  LR_FC_WHY="needs rebase: conflicts with origin/$2 in $(head -n 5 <<<"$paths" | paste -sd' ' -)"
  [ "$n" -gt 5 ] && LR_FC_WHY="$LR_FC_WHY (+$((n - 5)) more)"
  return 0
}

# lr_fresh_supersede <id> <job> <sha> <key> — posts outcome superseded with
# LR_FC_WHY as the detail and no verdict, then the job done. A failed post
# returns with the job left for the watchdog and claims nothing.
lr_fresh_supersede() {
  post_result "$1" "$(jq -nc --arg j "$2" --arg s "$3" --arg d "$LR_FC_WHY" \
    '{job_id:$j,head_sha:$s,outcome:"superseded",detail:$d}')" || return
  job_update "$2" status=done; log "superseded $4: $LR_FC_WHY; no agent call"; R=superseded
}

#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/90-caps.sh — gate 13 of bin/lead-review-enqueue.sh, the
# caps and the tripwire, ported to the worklist. It runs BEFORE review_one's
# job_open, so a capped head makes no job POST. In order:
#   1. LEAD_REVIEW_ENQUEUE_MAX_PER_TICK, the enqueue lane's required knob
#      (lgk_load): a registry read that failed (lane_env_apply rc != 0), or a
#      value that is not a positive integer, holds EVERY worklist head, rc 11,
#      with one log line a process. Empty is never "no cap".
#   2. LEAD_REVIEW_MAX_PER_PR_DAY, the dispatcher's own knob (lane_env_apply
#      lead-review): not a positive integer, or no lw_pr_day_ok, holds the
#      same way.
#   3. lw_pr_day_ok (bin/lib/lead-worklist.sh, state/lead-review/started.tsv:
#      agent calls this UTC day on this box) says the PR is at the cap:
#      lw_pr_day_trip (ONE lane-alert lead-trip-<slug_>-<n>-<day> a PR a day),
#      one `[skip pr-day-cap]` line, rc 10.
#   4. LEAD_REVIEW_ENQUEUE_MAX_PER_TICK heads already passed this gate in this
#      process: one `[skip deferred]` line, rc 11; the next tick offers it.
#   5. Otherwise the head takes one of this tick's places, rc 0.
# A head a later gate holds keeps its place: fewer starts, never more.
# Request rows never pass the gates, so they are not counted here.
# Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/lead-gates-knobs.sh
command -v lgk_load >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-gates-knobs.sh" 2>/dev/null || true

declare -g _LGC_PASSED=0

lg_gate_caps() {
  local slug="$1" n="$2" head h12="${3:0:12}" maxd="${LEAD_REVIEW_MAX_PER_PR_DAY:-}"
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  if ! command -v lgk_load >/dev/null 2>&1; then
    _lgt_once lgc-nolib "bin/lib/lead-gates-knobs.sh missing; LEAD_REVIEW_ENQUEUE_MAX_PER_TICK unreadable, every worklist head is held"
    return 11
  fi
  lgk_load
  if [ "$LGK_RC" != 0 ] || ! [[ "$LGK_MAXT" =~ ^[1-9][0-9]*$ ]]; then
    _lgt_once lgc-maxt "LEAD_REVIEW_ENQUEUE_MAX_PER_TICK='$LGK_MAXT' unreadable (rc $LGK_RC); every worklist head is held"
    return 11
  fi
  if ! [[ "$maxd" =~ ^[1-9][0-9]*$ ]] || ! command -v lw_pr_day_ok >/dev/null 2>&1; then
    _lgt_once lgc-maxd "LEAD_REVIEW_MAX_PER_PR_DAY='$maxd' unreadable (or no lw_pr_day_ok); every worklist head is held"
    return 11
  fi
  if ! lw_pr_day_ok "$slug" "$n"; then
    command -v lw_pr_day_trip >/dev/null 2>&1 && lw_pr_day_trip "$slug" "$n"
    lgs_skip_once "$slug" "$n" "$head" pr-day-cap \
      "$maxd lead reviews of this PR today (LEAD_REVIEW_MAX_PER_PR_DAY=$maxd); not started"
    return 10
  fi
  if [ "$_LGC_PASSED" -ge "$LGK_MAXT" ]; then
    lgs_skip_once "$slug" "$n" "$head" deferred "LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=$LGK_MAXT reached; offered next tick"
    return 11
  fi
  _LGC_PASSED=$((_LGC_PASSED + 1))
  return 0
}

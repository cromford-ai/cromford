#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates-knobs.sh — the lead-review lane's knobs for the worklist
# gates (bin/lib/lead-gates.d/57..97). They moved from the
# lead-review-enqueue lane (BH-5878). Sourced by those gate files, never run.
#
#   lgk_load   reads the knobs ONCE per process: `lane_env_apply lead-review`
#       runs in a subshell (the pattern of 10-builder.sh). LGK_RC is the
#       subshell's rc (75 = the registry declares a required knob with no row,
#       no env and no default). Without lane_env_apply the values come from the
#       current env and LGK_RC is 0. Always rc 0; the readers judge LGK_RC.
#
# Each knob, its default and its reader. Every reader applies the default and
# validation the enqueue used, so one row is never read two ways:
#   LGK_MAXT      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK   required (registry 15), none here:
#                 empty or not a positive integer = hold        90-caps.sh
#   LGK_RETRYMAX  LEAD_REVIEW_FAILED_RETRY_MAX       2           95-retry-reclaim.sh
#   LGK_PSC       PR_SELF_CHECK                      1 (0 = off) 75, 78
#   LGK_PSCMAX    PR_SELF_CHECK_MAX_WAIT_MIN         30          75, 78
#   LGK_TWAIT     LEAD_REVIEW_TRACED_WAIT            1 (0 = off) 57-traced-hold.sh
#   LGK_TJOB      LEAD_REVIEW_TRACED_JOB             "Tests, traced"
#   LGK_TWF       LEAD_REVIEW_TRACED_WORKFLOW        harness-ci.yml
#   LGK_TMAX      LEAD_REVIEW_TRACED_MAX_WAIT_MIN    30
#   LGK_RBHOLD    LEAD_REVIEW_REBASE_HOLD            1 (0 = off) 85, 57

declare -g _LGK_DONE="" LGK_RC=0 LGK_MAXT="" LGK_RETRYMAX="" LGK_PSC="" LGK_PSCMAX=""
declare -g LGK_TWAIT="" LGK_TJOB="" LGK_TWF="" LGK_TMAX="" LGK_RBHOLD=""

# _lgk_print — one knob a line, in the order lgk_load reads them back.
_lgk_print() {
  printf '%s\n' "${LEAD_REVIEW_ENQUEUE_MAX_PER_TICK:-}" "${LEAD_REVIEW_FAILED_RETRY_MAX:-}" \
    "${PR_SELF_CHECK:-}" "${PR_SELF_CHECK_MAX_WAIT_MIN:-}" "${LEAD_REVIEW_TRACED_WAIT:-}" \
    "${LEAD_REVIEW_TRACED_JOB:-}" "${LEAD_REVIEW_TRACED_WORKFLOW:-}" \
    "${LEAD_REVIEW_TRACED_MAX_WAIT_MIN:-}" "${LEAD_REVIEW_REBASE_HOLD:-}" | tr -d '\r'
}

lgk_load() {
  local out rc=0 v=()
  [ -n "$_LGK_DONE" ] && return 0
  _LGK_DONE=1
  if command -v lane_env_apply >/dev/null 2>&1; then
    out=$(lane_env_apply lead-review >/dev/null 2>&1; _lgk_print) || rc=$?
  else
    out=$(_lgk_print)
  fi
  LGK_RC=$rc
  mapfile -t v <<<"$out"
  [ "$rc" = 0 ] || v=()
  LGK_MAXT="${v[0]:-}"
  LGK_RETRYMAX="${v[1]:-2}"; [[ "$LGK_RETRYMAX" =~ ^[0-9]+$ ]] || LGK_RETRYMAX=2
  LGK_PSC="${v[2]:-1}"; [ "$LGK_PSC" = 0 ] || LGK_PSC=1
  LGK_PSCMAX="${v[3]:-30}"; [[ "$LGK_PSCMAX" =~ ^[0-9]{1,5}$ ]] || LGK_PSCMAX=30
  LGK_TWAIT="${v[4]:-1}"; [ "$LGK_TWAIT" = 0 ] || LGK_TWAIT=1
  LGK_TJOB="${v[5]:-}"; [ -n "$LGK_TJOB" ] || LGK_TJOB="Tests, traced"
  LGK_TWF="${v[6]:-}"; [ -n "$LGK_TWF" ] || LGK_TWF="harness-ci.yml"
  LGK_TMAX="${v[7]:-30}"; [[ "$LGK_TMAX" =~ ^[0-9]{1,5}$ ]] || LGK_TMAX=30
  LGK_RBHOLD="${v[8]:-1}"; [ "$LGK_RBHOLD" = 0 ] || LGK_RBHOLD=1
  return 0
}

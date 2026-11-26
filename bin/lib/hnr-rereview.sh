# shellcheck shell=bash
# bin/lib/hnr-rereview.sh — ANOTHER LANE'S BLOCK ON A MOVED HEAD BUYS THE
# CONDUCTOR'S OWN READ BEFORE IT PARKS, CAPPED PER PR (BH-9693, scope 2 of
# BH-9427 `head-not-reapproved`).
#
# Sourced by bin/merge-conductor.d/bh-9693-hnr-rereview.sh and
# bin/blocked-resolver.d/bh-9693-hnr-rereview.sh. Functions only; no side
# effect at source time. Needs mc_attempt_put / mc_attempt_has /
# mc_attempt_count (bin/lib/mc/locks.sh) at call time.
#
# THE RULE. A BLOCK that the conductor did not buy (the >12h review autopilot,
# or a bound verdict from review-prs, a box or run-build) parked the PR on
# sight as `head-not-reapproved`, and no read by the conductor ever looked at
# the head. Now the PR gets MC_HNR_REREVIEW_MAX such heads where the conductor
# buys its own head-bound read first. The conductor's own verdict then decides:
# APPROVE rebinds, BLOCK parks once per head. When the budget is used, the
# park is today's park, and the log line and the comment name the cap.
#
# THE COUNTER. One attempts line `hnrbuy <owner/repo#num> <head>` per head
# the budget paid for, written BEFORE the spend. mc_attempt_count hnrbuy <key>
# is the number used.
#
# THE KNOB. MC_HNR_REREVIEW_MAX (registry row: catalog/lanes.d/_lib.hnr-rereview.json,
# default 1, 0 = off: every foreign BLOCK parks on sight, as before this lib).
#
# The harness root is ${HARNESS:-${H:-}} and nothing else (D43).

# mc_hnr_max — the per-PR budget. Reads the registry row once per process
# through lib_env_apply hnr-rereview. Not a number reads as the fallback 1
# (the default of the row in catalog/lanes.d/_lib.hnr-rereview.json).
mc_hnr_max() {
  local v
  if [ -z "${_MC_HNR_ENV:-}" ]; then
    _MC_HNR_ENV=1
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply hnr-rereview >/dev/null 2>&1
  fi
  v="${MC_HNR_REREVIEW_MAX:-}"
  [[ "$v" =~ ^[0-9]+$ ]] || v=1
  printf '%s' "$((10#$v))"
}

# mc_hnr_used <key> — the number of heads of this PR the budget paid for.
mc_hnr_used() {
  [ -n "${1:-}" ] || { printf '0'; return 0; }
  mc_attempt_count hnrbuy "$1"
}

# mc_hnr_decide <key> <head> <source> <ci> <mstate>
#   Prints ONE line `<word>\t<why>` and sets MC_HNR_WORD and MC_HNR_WHY (when
#   it is not run in a subshell). <word>:
#     buy   fall through to the conductor's own head-bound read; do not park.
#           <why> is `unit <n> of <max>` when this call took the unit (the
#           caller says so once), and empty when the head already had one.
#     wait  CI is not done; no unit is taken, and the spawn path defers.
#     park  today's park. <why> names the reason (the cap, CI, the knob).
#   <ci> is the conductor's word (green|pending|red|none|...), or `any` for
#   the resolver, whose rung buys whatever CI says.
#   Always rc 0.
mc_hnr_decide() {
  local key="${1:-}" head="${2:-}" src="${3:-}" ci="${4:-}" ms="${5:-}" max used word="" why=""
  max=$(mc_hnr_max)
  if [ "$max" = 0 ]; then
    word=park; why="off (MC_HNR_REREVIEW_MAX=0)"
  elif [ -z "$key" ] || [ -z "$head" ]; then
    word=park; why="no PR key or head to count against"
  else
    case "$src" in
      autopilot|review-prs|box|run-build) ;;
      *) word=park; why="" ;;   # lead, human, our own mc-rereview, empty, unknown: today's park
    esac
    if [ -z "$word" ] && [ "$ms" = DIRTY ]; then
      word=park; why="the head is DIRTY and no read can run on it"
    fi
    if [ -z "$word" ]; then
      case "$ci" in
        green|pending|none|any) ;;
        *) word=park; why="CI $ci on ${head:0:8}: the fix round owns a red head" ;;
      esac
    fi
    if [ -z "$word" ] && mc_attempt_has "hnrbuy $key $head" 2>/dev/null; then
      word=buy; why=""
    fi
    if [ -z "$word" ]; then
      used=$(mc_hnr_used "$key")
      [[ "$used" =~ ^[0-9]+$ ]] || used=0
      if [ "$used" -ge "$max" ]; then
        word=park; why="re-review budget used ($used of $max)"
      elif [ "$ci" = pending ] || { [ "$ci" = none ] && ! { [ -n "${MC_FLAKE:-}" ] && [ "${MC_FLAKE_RUNG:-0}" -ge 2 ]; }; }; then
        # No unit for a head that is still building: the spawn path's own CI
        # debounce defers. A spent flake ladder (rung 2) buys without CI, so
        # it takes its unit like a green head.
        word=wait; why="CI $ci on ${head:0:8}"
      else
        mc_attempt_put "hnrbuy $key $head"
        word=buy; why="unit $((used + 1)) of $max"
      fi
    fi
  fi
  MC_HNR_WORD="$word"; MC_HNR_WHY="$why"
  printf '%s\t%s\n' "$word" "$why"
  return 0
}

# mc_hnr_reuse <key> <head> <say-prefix> — br_rereview's reuse rung
# (bin/blocked-resolver.sh). Sets the caller's `reused` to RB_SOURCE (the
# verdict review_bought found on this head). ANOTHER MACHINE LANE'S BLOCK IS
# NOT REUSED WHILE THE PR'S RE-REVIEW BUDGET HAS ROOM: then `reused` is empty
# and the rung buys the read. Budget used, a lead/human/own source, or an
# APPROVE: today's reuse. It lives here and not in the driver because the
# driver is at its line ceiling (tests/br-driver-unjoin.bh-8626-test.sh U2).
#   Always rc 0.
mc_hnr_reuse() {
  local hnr="" hnrwhy=""
  reused="${RB_SOURCE:-}"
  [ "${RB_CLASS:-}" != approve ] || return 0
  IFS=$'\t' read -r hnr hnrwhy < <(mc_hnr_decide "${1:-}" "${2:-}" "${RB_SOURCE:-}" any -)
  [ "$hnr" = buy ] || return 0
  declare -F say >/dev/null 2>&1 \
    && say "${3:-}: $RB_SOURCE's ${RB_WORD:-BLOCK} on ${2:0:8} is not reused — the re-review budget has room (${hnrwhy:-unit already taken for this head}); buying the read"
  reused=""
  return 0
}

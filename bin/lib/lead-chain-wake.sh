#!/bin/bash
# bin/lib/lead-chain-wake.sh — the lead-chain doorbell (BH-4057, contract
# slice BH-4092). Sourced, never run.
#
# WHY IT EXISTS. The lead chain crosses boxes: the worklist gates
# (bin/lib/lead-gates.d/) ask for a review, bin/lead-review.sh runs it on
# the box that owns the repo, and the hub's bin/lead-review-land.sh lands its
# answer. Each stage advanced only on its own cron tick, so a review waited out
# up to three clocks it had nothing to do with. A local launch cannot cross a
# box, so the ring is a row in the D1 `wakes` table (POST /api/wakes/lane), and
# bin/wake-loop.sh on the box that claims the row launches the lane's own
# script. The crons stay the backstop: a ring that is refused, deduped or lost
# costs one tick of latency, never a review.
#
# BOUNDED. One row per PR head per stage: the worker's INSERT OR IGNORE on
# idx_wakes_dedupe with minute 'lane:<kind>:<pr>@<sha12>'. The loop launches
# at most once per drain. A rerun is depth-bounded by the caller's knob.
#
# KILL SWITCH: lead-chain-wake-off, read through lane_switch in `file` mode (a
# settings row first, else flags/lead-chain-wake-off). It stops every ring here
# and both launches in bin/wake-loop.sh.
#
# THE TWO HELPERS, called by the siblings unchanged:
#
# lcw_ring <kind> <owner/repo> <pr> <head-sha>
#   Rings <kind> (lead-review|lead-land) for that PR head, through
#   wake_lane_put (bin/jobs-client.sh must already be sourced). The dedupe is
#   <kind>:<pr>@<head[0:12]>. Never prints, never exits, safe under set -u.
#   rc 0  rung (the worker answered 2xx)
#   rc 1  not rung on purpose: the kill switch is on (or unreadable), or the
#         input is bad (kind empty, slug not owner/repo, pr not all digits,
#         head not 40 hex after lowercasing). Nothing is called.
#   rc 2  not rung: wake_lane_put is not defined, or the worker refused or was
#         unreachable (a 404 until the route is deployed).
#
# lcw_rerun <script-path> <state-dir> <max-knob-value> [force] [args...]
#   Re-launches <script-path> [args...] once, detached, when a rerun is owed:
#   <state-dir>/rerun-owed exists, or force is 1. The 4th argument is `force`
#   only when it is 0 or 1; anything else is the first of [args...].
#   Canonical call: lcw_rerun "$0" "$STATE" "$KNOB" 0 tick
#   The child runs with LEAD_CHAIN_RERUN_DEPTH one higher than this shell's
#   (unset or not an integer = 0), with fd 9 closed in this shell first, so a
#   tick lock held on fd 9 is released, never inherited.
#   rc 0  launched; prints `rerun owed (depth <d+1>/<max>)` and removes the marker
#   rc 1  not launched:
#         no trigger                 silent
#         knob empty, not digits, 0  `rerun owed but off (max='<v>')`, marker kept
#         depth >= max               `rerun owed but depth <d>/<max> reached;
#                                    cron covers it`, marker removed
#         script not executable      `rerun owed but <script> is not executable`

_lcw_home() { printf '%s' "${HARNESS:-${H:-}}"; }

# _lcw_off — rc 0 when the kill switch is on, or cannot be read at all.
_lcw_off() {
  local r
  command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null || true
  if command -v lane_switch >/dev/null 2>&1; then
    lane_switch lead-chain-wake-off file
    return
  fi
  r=$(_lcw_home)
  [ -n "$r" ] || return 0
  r="$r/flags/lead-chain-wake-off"
  [ -f "$r" ]
}

lcw_ring() {
  local kind="${1:-}" slug="${2:-}" pr="${3:-}" head="${4:-}"
  _lcw_off && return 1
  [ -n "$kind" ] || return 1
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$pr" =~ ^[0-9]+$ ]] || return 1
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  command -v wake_lane_put >/dev/null 2>&1 || return 2
  wake_lane_put "$slug" "$kind" "$pr" "$kind:$pr@${head:0:12}" >/dev/null 2>&1 || return 2
  return 0
}

lcw_rerun() {
  local script="${1:-}" state="${2:-}" max="${3:-}" force=0 d
  [ "$#" -ge 3 ] && shift 3 || shift "$#"
  case "${1:-}" in 0|1) force="$1"; shift ;; esac
  d="${LEAD_CHAIN_RERUN_DEPTH:-0}"
  case "$d" in ''|*[!0-9]*) d=0 ;; esac
  if [ "$force" != 1 ]; then
    [ -n "$state" ] && [ -e "$state/rerun-owed" ] || return 1
  fi
  case "$max" in
    ''|*[!0-9]*) echo "rerun owed but off (max='$max')"; return 1 ;;
  esac
  [ "$((10#$max))" -gt 0 ] || { echo "rerun owed but off (max='$max')"; return 1; }
  max=$((10#$max))
  if [ "$d" -ge "$max" ]; then
    echo "rerun owed but depth $d/$max reached; cron covers it"
    [ -n "$state" ] && rm -f "$state/rerun-owed"
    return 1
  fi
  [ -n "$script" ] && [ -x "$script" ] || { echo "rerun owed but ${script:-<none>} is not executable"; return 1; }
  [ -n "$state" ] && rm -f "$state/rerun-owed"
  flock -u 9 2>/dev/null; exec 9>&-
  ( LEAD_CHAIN_RERUN_DEPTH=$((d + 1)) setsid "$script" "$@" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  echo "rerun owed (depth $((d + 1))/$max)"
  return 0
}

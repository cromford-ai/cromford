# shellcheck shell=bash
# bin/lib/execute-no-progress.sh — BH-8868: stop an execute session that has
# changed no file. Sourced by bin/agent-call.sh, never run. Defining functions
# is its only effect at source time.
#
# WHY. project-6-os TK-3225: the execute session ran 3510 s and read 54.2M
# context tokens with 0 file changes, until the context kill at its 53.6M
# ceiling. Nothing stopped a session that wrote nothing.
#
# HOW. agent-call's context meter (context_meter) runs beside every metered
# claude session. When np_armed says yes, run_attempt takes a worktree
# fingerprint (np_snapshot) before the CLI starts, and on every meter poll the
# meter takes a new one and asks np_decide. On `stop` it writes $OUT.noprogress
# and TERMs the child. agent-call treats it as a policy stop (rc 143, no model
# escalation, no vendor failover) and bin/lib/rb/execute.sh ends the build with
# RESULT `EXECUTE_EMPTY EXECUTE_NO_PROGRESS: ...` and keeps the transcript.
#
# THE KNOBS (catalog/lanes.d/_lib.execute-no-progress.json, resolved at call
# time by lib_env_apply execute-no-progress: settings row > env > registry):
#   EXECUTE_NO_WRITE_STOP_MIN          default 20 (settings row
#       lib.execute-no-progress.execute_no_write_stop_min). 0 = time rule off.
#   EXECUTE_NO_WRITE_STOP_CEILING_PCT  default 50 (settings row
#       lib.execute-no-progress.execute_no_write_stop_ceiling_pct). 0 = off.
# Both 0 = the check is not armed.
#
# THE FUNCTIONS
#   np_knobs            sets _NP_MIN and _NP_PCT.
#   np_armed <stage> <cwd>   rc 0 only for stage execute, a knob > 0 and a git
#                       worktree at <cwd>. Calls np_knobs.
#   np_snapshot <cwd>   one fingerprint line: HEAD and a sha1 of the porcelain
#                       status (with size and mtime of each listed path), minus
#                       node_modules/, .next/ and __pycache__/. rc 1 and no
#                       output when git fails: the caller counts that as a
#                       change (fail-open, never stop on our own read failure).
#   np_decide <elapsed_s> <total> <ceiling> <changed> <min> <pct>   pure.
#                       stop when changed is 0 AND (elapsed >= min*60, min > 0,
#                       OR total*100 >= ceiling*pct, pct > 0 and ceiling > 0).
#                       Prints `stop<TAB>rule=time|ceiling<TAB>...` or `ok<TAB>...`.
#                       A non-integer input disables only the rule that needs it.
#   _np_now             date -u +%s, or NP_NOW when set (a test clock).

_NP_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
_np_now() { if [ -n "${NP_NOW:-}" ]; then printf '%s' "$NP_NOW"; else date -u +%s; fi; }
_np_int() { # _np_int <value> -> the value when it is a non-negative integer, else nothing
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$((10#$1))" ;; esac
}

# The _tw_knobs pattern (bin/lib/build-tripwire.sh): lib_env_apply runs in a
# subshell, so its fail-closed exit cannot stop the caller, and the EXIT trap
# hands back on fd 3 every knob that resolved.
np_knobs() {
  local kv k v
  kv=$(
    exec 3>&1
    command -v lib_env_apply >/dev/null 2>&1 || . "$_NP_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_NP_LIB/lanes-registry.sh" >/dev/null 2>&1; then
      LANE_REGISTRY=$(lanes_json_path "$_NP_LIB/../.." 2>/dev/null) && export LANE_REGISTRY
    fi
    trap 'for k in EXECUTE_NO_WRITE_STOP_MIN EXECUTE_NO_WRITE_STOP_CEILING_PCT; do printf "%s\t%s\n" "$k" "${!k:-}" >&3; done' EXIT
    lib_env_apply execute-no-progress >/dev/null 2>&1) || true
  # Fallbacks: the rows lib.execute-no-progress.execute_no_write_stop_min (20)
  # and lib.execute-no-progress.execute_no_write_stop_ceiling_pct (50).
  _NP_MIN=$(_np_int "${EXECUTE_NO_WRITE_STOP_MIN:-20}") || _NP_MIN=20
  _NP_PCT=$(_np_int "${EXECUTE_NO_WRITE_STOP_CEILING_PCT:-50}") || _NP_PCT=50
  while IFS=$'\t' read -r k v; do
    v=$(_np_int "$v") || continue
    case "$k" in
      EXECUTE_NO_WRITE_STOP_MIN)         _NP_MIN="$v" ;;
      EXECUTE_NO_WRITE_STOP_CEILING_PCT) _NP_PCT="$v" ;;
    esac
  done <<<"$kv"
  return 0
}

np_armed() { # np_armed <stage> <cwd>
  [ "${1:-}" = execute ] || return 1
  np_knobs
  [ "${_NP_MIN:-0}" -gt 0 ] || [ "${_NP_PCT:-0}" -gt 0 ] || return 1
  [ -n "${2:-}" ] && git -C "$2" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

np_snapshot() { # np_snapshot <cwd>
  local cwd="${1:-}" head st p sz
  [ -n "$cwd" ] || return 1
  head=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || return 1
  st=$(git -C "$cwd" status --porcelain=v1 -uall 2>/dev/null) || return 1
  st=$(printf '%s\n' "$st" | grep -vE '(^|/)(node_modules|\.next|__pycache__)/' \
    | while IFS= read -r p; do
        [ -n "$p" ] || continue
        # Size and mtime too: an edit to a file already dirty at the start
        # leaves its porcelain line the same.
        sz=$(stat -c '%s %Y' "$cwd/${p:3}" 2>/dev/null || stat -f '%z %m' "$cwd/${p:3}" 2>/dev/null)
        printf '%s %s\n' "$p" "$sz"
      done | sha1sum | cut -c1-40)
  printf '%s %s\n' "$head" "$st"
}

np_decide() { # np_decide <elapsed_s> <total> <ceiling> <changed> <min> <pct>
  local el tot cap ch="${4:-}" min pct
  el=$(_np_int "${1:-}") || el=""
  tot=$(_np_int "${2:-}") || tot=""
  cap=$(_np_int "${3:-}") || cap=""
  min=$(_np_int "${5:-}") || min=0
  pct=$(_np_int "${6:-}") || pct=0
  local tail="elapsed_s=${el:-?}	total=${tot:-?}	ceiling=${cap:-?}	min=$min	pct=$pct"
  # Only an explicit 0 is "no change": anything else is fail-open.
  if [ "$ch" != 0 ]; then printf 'ok\t%s\n' "$tail"; return 0; fi
  if [ "$min" -gt 0 ] && [ -n "$el" ] && [ "$el" -ge $((min * 60)) ]; then
    printf 'stop\trule=time\t%s\n' "$tail"; return 0
  fi
  if [ "$pct" -gt 0 ] && [ -n "$tot" ] && [ -n "$cap" ] && [ "$cap" -gt 0 ] && [ $((tot * 100)) -ge $((cap * pct)) ]; then
    printf 'stop\trule=ceiling\t%s\n' "$tail"; return 0
  fi
  printf 'ok\t%s\n' "$tail"
}

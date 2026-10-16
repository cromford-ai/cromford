# shellcheck shell=bash
# bin/lib/wake-backstop.sh — BH-6976 (BH-6545.3): the one read-now-or-skip
# decision for a poller whose full poll became a backstop. Sourced, never run.
#
#   wb_due <slug> <kinds> <keys-file|-> <last-epoch> <floor-s> <backstop-s> [<key>...]
#       rc 0 = read now, rc 1 = skip (nothing changed). One reason word on
#       stdout. <kinds> is a comma list (`issue`, `issue,pr`). With `-` for the
#       keys file, the keys are the trailing arguments. First match wins:
#         1. WAKE_BACKSTOP=0, or backstop 0          rc 0 off
#         2. last-epoch empty, non-digit, 0 or ahead rc 0 no-state
#         3. now - last < floor                      rc 1 floor
#         4. now - last >= backstop                  rc 0 backstop
#         5. no prs_wake_seen after a load attempt   rc 0 no-feed
#         6. keys file missing or unreadable         rc 0 no-keys
#            a `retry` line in it                    rc 0 retry
#            more than WB_MAX_KEYS (200) keys        rc 0 many-keys
#         7. prs_wake_seen <slug> <kind> <key> <last> rc 0  rc 0 wake:<kind>:<key>
#                                                    rc 2  rc 0 no-feed
#         8. every answer rc 1                       rc 1 quiet
#       A backstop of 1-1799 reads as 1800 (the ticket's floor), with one line
#       in logs/wake-backstop.log per UTC day.
#   wb_knob <ENV>      the resolved value of WAKE_BACKSTOP (0|1, default 1),
#                      ORPHAN_WAKE_BACKSTOP_S or PARENT_CLOSE_BACKSTOP_S
#                      (digits, default 1800). Anything else prints nothing, rc 1.
#   wb_cache_put <base> <meta>   stdin to <base>.json, then <meta> to
#                      <base>.meta, each through tmp + mv; the meta goes last,
#                      so a torn write is a miss, never a stale hit.
#   wb_cache_get <base> <slug> <kinds> <key> <backstop-s> <updated|->
#                      rc 0 when <base>.json may be used instead of a read: the
#                      meta is `<updated>\t<epoch>`, its <updated> equals the one
#                      given (`-` for a read with no updatedAt; an empty one
#                      never hits), and wb_due on the
#                      meta's epoch with floor 0 answers rc 1. Else rc 1.
#   wb_gc <dir>        delete the cache files under <dir> older than 3 days
#                      (a mechanism bound, prs_gc's horizon).
#
# READ, NEVER ACK: the wakes come from prs_wake_seen (bin/lib/pr-snapshot-wakes.sh),
# the read-only mirror of the worker's wakes table. This lib makes no GitHub
# call and claims no wake, so bin/wake-loop.sh's cursor is untouched. When the
# feed cannot tell, the answer is read now: a feed outage restores the old
# cadence and never hides a change.
#
# The root is ${HARNESS:-${H:-}} and nothing else. No `set -e`, no `exit`.
if [ -n "${WAKE_BACKSTOP_LIB:-}" ]; then return 0 2>/dev/null; fi
WAKE_BACKSTOP_LIB=1
WB_MAX_KEYS=200
WB_FLOOR_S=1800

# The knobs, resolved once, the bin/lib/pr-snapshot.sh way: lib_env_apply in a
# SUBSHELL, handing back on fd 3 whatever resolved, so a fail-closed exit there
# never stops the lane that sourced this file.
_WB_KV=$(
  exec 3>&1
  _WB_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_WB_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_WB_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_WB_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _WB_K in WAKE_BACKSTOP ORPHAN_WAKE_BACKSTOP_S PARENT_CLOSE_BACKSTOP_S; do printf "%s\t%s\n" "$_WB_K" "${!_WB_K:-}" >&3; done' EXIT
  lib_env_apply wake-backstop >/dev/null 2>&1)
while IFS=$'\t' read -r _WB_K _WB_V; do
  if [ -n "$_WB_V" ]; then printf -v "$_WB_K" '%s' "$_WB_V"; fi
done <<<"$_WB_KV"
unset _WB_KV _WB_K _WB_V

_wb_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$((10#$1))" ;; esac; }
_wb_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && _wb_int "${WAKE_BACKSTOP_NOW:-}" >/dev/null; then
    printf '%s' "$((10#$WAKE_BACKSTOP_NOW))"
  else date +%s; fi
}

wb_knob() {
  local v
  case "${1:-}" in
    WAKE_BACKSTOP)
      v="${WAKE_BACKSTOP:-1}"
      [ "$v" = 0 ] && { printf 0; return 0; }
      printf 1 ;;
    ORPHAN_WAKE_BACKSTOP_S|PARENT_CLOSE_BACKSTOP_S)
      v=$(_wb_int "${!1:-}") || v="$WB_FLOOR_S"
      printf '%s' "$v" ;;
    *) return 1 ;;
  esac
}

# _wb_clamp_log <value> — the once-a-day line for a backstop under the floor.
_wb_clamp_log() {
  local h="${HARNESS:-${H:-}}" day f
  [ -n "$h" ] || return 0
  day=$(date -u +%Y-%m-%d)
  f="$h/logs/wake-backstop.log"
  grep -q "^$day.* backstop $1 " "$f" 2>/dev/null && return 0
  mkdir -p "$h/logs" 2>/dev/null || return 0
  printf '%s wake-backstop: backstop %s s is under the %s s floor; read as %s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" "$WB_FLOOR_S" "$WB_FLOOR_S" >> "$f" 2>/dev/null
  return 0
}

wb_due() {
  local slug="${1:-}" kinds="${2:-}" kf="${3:-}" last="${4:-}" floor="${5:-}" back="${6:-}"
  local now age k kind rc line _l
  local -a keys=()
  shift 6 2>/dev/null || set --
  if [ "$(wb_knob WAKE_BACKSTOP)" = 0 ]; then echo off; return 0; fi
  back=$(_wb_int "$back") || back="$WB_FLOOR_S"
  [ "$back" -gt 0 ] || { echo off; return 0; }
  if [ "$back" -lt "$WB_FLOOR_S" ]; then _wb_clamp_log "$back"; back="$WB_FLOOR_S"; fi
  last=$(_wb_int "$last") && [ "$last" -gt 0 ] || { echo no-state; return 0; }
  floor=$(_wb_int "$floor") || floor=0
  now=$(_wb_now)
  age=$((now - last))
  [ "$age" -ge 0 ] || { echo no-state; return 0; }
  [ "$age" -lt "$floor" ] && { echo floor; return 1; }
  [ "$age" -ge "$back" ] && { echo backstop; return 0; }
  if [ "$(type -t prs_wake_seen)" != function ]; then
    _l="$(dirname "${BASH_SOURCE[0]}")/pr-snapshot.sh"
    # shellcheck source=bin/lib/pr-snapshot.sh
    [ -r "$_l" ] && . "$_l" >/dev/null 2>&1
  fi
  [ "$(type -t prs_wake_seen)" = function ] || { echo no-feed; return 0; }
  if [ "$kf" = - ]; then
    keys=("$@")
  else
    [ -n "$kf" ] && [ -r "$kf" ] || { echo no-keys; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line//[[:space:]]/}"
      [ -n "$line" ] || continue
      [ "$line" = retry ] && { echo retry; return 0; }
      keys+=("$line")
    done < "$kf"
  fi
  [ "${#keys[@]}" -gt "$WB_MAX_KEYS" ] && { echo many-keys; return 0; }
  for k in "${keys[@]}"; do
    for kind in ${kinds//,/ }; do
      rc=0; prs_wake_seen "$slug" "$kind" "$k" "$last" || rc=$?
      case "$rc" in
        0) echo "wake:$kind:$k"; return 0 ;;
        1) ;;
        *) echo no-feed; return 0 ;;
      esac
    done
  done
  echo quiet
  return 1
}

wb_cache_put() {
  local base="$1" meta="$2"
  mkdir -p "$(dirname "$base")" 2>/dev/null || return 1
  rm -f "$base.meta" 2>/dev/null
  cat > "$base.json.tmp.$$" 2>/dev/null && mv -f "$base.json.tmp.$$" "$base.json" 2>/dev/null \
    && printf '%s\n' "$meta" > "$base.meta.tmp.$$" 2>/dev/null && mv -f "$base.meta.tmp.$$" "$base.meta" 2>/dev/null
  local rc=$?
  rm -f "$base.json.tmp.$$" "$base.meta.tmp.$$" 2>/dev/null
  return "$rc"
}

wb_cache_get() {
  local base="$1" slug="$2" kinds="$3" key="$4" back="$5" want="${6:-}" u e
  [ -n "$want" ] || return 1
  [ -r "$base.json" ] && [ -r "$base.meta" ] || return 1
  IFS=$'\t' read -r u e < "$base.meta" || return 1
  [ -n "$u" ] && [ "$u" = "$want" ] || return 1
  _wb_int "$e" >/dev/null || return 1
  # wb_due rc 1 is "skip the read": the cached answer stands.
  wb_due "$slug" "$kinds" - "$e" 0 "$back" "$key" >/dev/null && return 1
  return 0
}

wb_gc() {
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  find "$1" -type f \( -name '*.json' -o -name '*.meta' -o -name '*.tmp.*' \) -mtime +3 -delete 2>/dev/null
  return 0
}

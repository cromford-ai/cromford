# shellcheck shell=bash
# bin/lib/unblock/scope.sh — BH-7727 (UNB-5): which projects the unblock lane
# (Tackler) may touch, and how. Sourced, never executed. Defines functions
# only; bin/lib/lane-gate.sh and bin/lib/project-lanes.sh are sourced lazily,
# inside the first call, with the caller's shell options kept.
#
# THE KEYS (settings rows, read through state/settings-cache.json):
#   unblock.project.<p>.mode      off | shadow | act. Missing = off.
#   unblock.standing_approval.<p> 1 = the project has standing approval for
#                                 the rules that need it (U4). Anything else
#                                 (0, true, yes, empty, missing) = not approved.
# <p> must match ^[a-z0-9][a-z0-9._-]{0,63}$ (the uo_active_projects key
# regex). It is never lowercased: `Cromford` is a bad name (rc 2). A key
# outside ^[a-z0-9_.-]{1,64}$ (the worker's SETTING_KEY_RE) is never read.
#
# THE GRAMMAR is act.sh's _ub_mode (gate 3), so this list and the writer agree
# on every row: strip every whitespace character, then exactly `act` or
# `shadow`. No case fold: `ACT` and `Shadow` read as off here and as
# no-opt-in in act.sh.
#
# FAIL CLOSED. A missing row, an empty value, any other value (`on`, `1`,
# `true`, `actt`, `ACT`), no settings cache, or no root all read as `off`. A stale cache (the worker did not answer) keeps the last known
# row, as conductor_mode (bin/lib/conductor-mode.sh) does. When lane-gate.sh
# cannot be loaded, setting_get answers if the caller has it; else `off`.
#
# THE CONTRACT:
#   unb_scope_mode <p>          prints off|shadow|act; rc 0, rc 2 (prints off)
#                               for a bad project name or no root
#   unb_scope_approved <p>      rc 0 only when the approval row is `1`; rc 1
#                               otherwise, rc 2 for a bad name
#   unb_scope_decide <p> <0|1>  needs_approval 1 = the action needs standing
#                               approval. Prints:
#                                 off                 -> skip
#                                 shadow              -> would, or would-escalate
#                                                        (needs approval, none)
#                                 act                 -> act, or escalate
#                                                        (needs approval, none)
#                               A needs_approval other than 0 or 1, or a bad
#                               project, prints skip, rc 2
#   unb_scope_projects          `<p><TAB><mode>` for each fleet.conf project
#                               whose mode is not off, in fleet.conf order. One
#                               fleet.conf read and one settings refresh
#   unb_scope_lock <p>          pl_lane_lock unblock <p>: locks/unblock-<p>.lock
#                               on fd 9 plus locks/unblock.lock shared on fd 4.
#                               rc 0 held, 1 busy, 2 bad name or no root. Never
#                               waits; one project never holds another
#
# The root is ${HARNESS:-${H:-}}; an empty root builds no path.
# act.sh re-reads the row live before any write; this lib never writes.
# Note: docs/notes/2026-10-21-bh-7727-unblock-opt-in.md

_UNB_SCOPE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

_unb_scope_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _unb_scope_ready — lane-gate.sh and project-lanes.sh loaded, the caller's
# shell options kept (lane-gate's client loader can set -uo pipefail).
# rc 0 when lane-gate's settings reader is there.
_unb_scope_ready() {
  local opts
  if ! command -v pl_lane_lock >/dev/null 2>&1; then
    opts=$(set +o)
    # shellcheck source=bin/lib/project-lanes.sh
    . "$_UNB_SCOPE_LIB/project-lanes.sh" >/dev/null 2>&1
    eval "$opts" 2>/dev/null
  fi
  command -v _lg_settings_refresh >/dev/null 2>&1 && return 0
  [ -r "$_UNB_SCOPE_LIB/lane-gate.sh" ] || return 1
  opts=$(set +o)
  # shellcheck source=bin/lib/lane-gate.sh
  . "$_UNB_SCOPE_LIB/lane-gate.sh" >/dev/null 2>&1
  eval "$opts" 2>/dev/null
  command -v _lg_settings_refresh >/dev/null 2>&1
}

# _unb_scope_name <p> — _UNB_P = <p>; rc 1 when it is not a project name.
_unb_scope_name() {
  _UNB_P=${1:-}
  [[ $_UNB_P =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
}

# _unb_scope_refresh — one settings refresh (the 60 s lane-gate cache), the
# caller's shell options kept. rc 1 when lane-gate cannot be loaded.
_unb_scope_refresh() {
  local opts
  _unb_scope_ready || return 1
  opts=$(set +o)
  _lg_settings_refresh
  eval "$opts" 2>/dev/null
  return 0
}

# _unb_scope_row <key> — _UNB_V = the row's value with every whitespace
# character removed (as act.sh _ub_mode); "" when there is no row.
_unb_scope_row() {
  local key="$1" v=""
  _UNB_V=""
  [[ $key =~ ^[a-z0-9_.-]{1,64}$ ]] || return 0
  if _unb_scope_ready; then
    [ "${_UNB_SCOPE_FRESH:-}" = 1 ] || _unb_scope_refresh
    _lg_setting_lookup_set "$key" && v=$_LG_SVAL
  elif command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get "$key" 2>/dev/null) || v=""
  fi
  _UNB_V=${v//[[:space:]]/}
}

# _unb_scope_mode_set <p> — _UNB_MODE = what unb_scope_mode prints, in this
# shell (no subshell per project in unb_scope_projects).
_unb_scope_mode_set() {
  _UNB_MODE=off
  [ -n "$(_unb_scope_root)" ] && _unb_scope_name "${1:-}" || return 2
  _unb_scope_row "unblock.project.$_UNB_P.mode"
  case "$_UNB_V" in shadow|act) _UNB_MODE=$_UNB_V ;; esac
  return 0
}

unb_scope_mode() {
  local rc=0
  _unb_scope_mode_set "${1:-}" || rc=$?
  printf '%s' "$_UNB_MODE"
  return "$rc"
}

unb_scope_approved() {
  _unb_scope_name "${1:-}" || return 2
  [ -n "$(_unb_scope_root)" ] || return 1
  _unb_scope_row "unblock.standing_approval.$_UNB_P"
  [ "$_UNB_V" = 1 ]
}

unb_scope_decide() {
  local p="${1:-}" need="${2:-}" mode
  case "$need" in 0|1) ;; *) printf skip; return 2 ;; esac
  _unb_scope_name "$p" || { printf skip; return 2; }
  mode=$(unb_scope_mode "$p")
  case "$mode" in
    shadow)
      if [ "$need" = 1 ] && ! unb_scope_approved "$p"; then printf would-escalate; else printf would; fi ;;
    act)
      if [ "$need" = 1 ] && ! unb_scope_approved "$p"; then printf escalate; else printf act; fi ;;
    *) printf skip ;;
  esac
  return 0
}

unb_scope_projects() {
  local root p projects mode
  root=$(_unb_scope_root)
  [ -n "$root" ] || return 0
  projects=$("$root/bin/fleet-conf.sh" --projects 2>/dev/null) || return 0
  # One settings refresh for the whole list, then cache reads only.
  _unb_scope_refresh
  local _UNB_SCOPE_FRESH=1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _unb_scope_mode_set "$p" || continue
    mode=$_UNB_MODE
    [ "$mode" = off ] || printf '%s\t%s\n' "$p" "$mode"
  done <<< "$projects"
  return 0
}

unb_scope_lock() {
  # The root is read BEFORE `local H`: inside the function a bare `local H`
  # shadows the caller's H with an empty value, so _unb_scope_root would read
  # an empty H whenever HARNESS is not exported (cron runs bin/unblock.sh with
  # H only). That made every tick log "lock held" with no lock (2026-10-26).
  local root
  root=$(_unb_scope_root)
  local H="$root"
  [ -n "$H" ] && _unb_scope_name "${1:-}" || return 2
  _unb_scope_ready
  command -v pl_lane_lock >/dev/null 2>&1 || return 2
  pl_lane_lock unblock "$_UNB_P"
}

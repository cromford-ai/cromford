#!/bin/bash
# bin/lib/claude-auth.sh — HOW a project pays for Claude, and whether its runs
# are locked to Claude (BH-9334). Sourced, never executed. Defines functions only.
#
#   . bin/lib/claude-auth.sh
#   claude_auth_mode <project>  -> `oauth` or `api-key` on stdout, rc 0
#   runner_lock_for <project>   -> `claude` or an empty line on stdout, rc 0
#   claude_auth_managed_guard   -> rc 0, or rc 1 + one stderr line (BH-9676)
#
# The answer is DATA: the settings rows `claude_auth.<project>` and
# `runner_lock.<project>`, read through lane-gate's settings fetch and its 60s
# cache, the same way bin/lib/project-account.sh reads `account.<project>`.
#
#   no row, or no settings answer at all  -> the default: `oauth` / no lock.
#                                            Behavior unchanged from before
#                                            BH-9334. There is no env fallback.
#   a row with an allowed value           -> that value.
#   a row with any other value            -> rc 1, empty stdout, one stderr line
#                                            naming the row. The caller decides
#                                            (a later slice refuses to build).
#   a project that is not [A-Za-z0-9._-]+ -> rc 1, empty stdout, one stderr line.
#
# The jobs worker (routes/settings.js PUT) accepts only the allowed values and
# only with the human verdict token, and signs each write into setting_sigs
# (PROTECTED_PREFIXES). So a bad value here came from a raw D1 write.
# The lists below are enums, not limits.
CLAUDE_AUTH_MODES="oauth api-key"
RUNNER_LOCKS="claude"

_cauth_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v _lg_setting_lookup >/dev/null 2>&1 && [ -r "$_cauth_dir/lane-gate.sh" ]; then
  . "$_cauth_dir/lane-gate.sh" >/dev/null 2>&1 || true
fi

# _cauth_read <row-prefix> <project> <default> <allowed...>
_cauth_read() {
  local pre="$1" p="$2" def="$3" v="" state=none a
  shift 3
  case "$p" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      printf 'claude-auth: %s<project>: %s is not a project name\n' "$pre" "${p:-(empty)}" >&2
      return 1 ;;
  esac
  if command -v _lg_setting_lookup >/dev/null 2>&1; then
    _lg_settings_refresh >/dev/null 2>&1 || true
    state=$(_lg_settings_state 2>/dev/null || printf none)
  fi
  if [ "$state" = none ]; then printf '%s\n' "$def"; return 0; fi
  if _lg_setting_lookup_set "$pre$p" 2>/dev/null; then
    v="$_LG_SVAL"
  elif [ -n "${_LG_SC_FILE:-}" ] && jq -e --arg k "$pre$p" '.values | has($k)' "$_LG_SC_FILE" >/dev/null 2>&1; then
    # The lookup answers "no row" for an EMPTY value too. An empty row is not
    # the default: the worker never writes one, so it is refused like any
    # other value outside the list.
    v=""
  else
    printf '%s\n' "$def"; return 0
  fi
  for a in "$@"; do
    [ "$v" = "$a" ] && { printf '%s\n' "$v"; return 0; }
  done
  printf "claude-auth: settings row %s%s is '%s', not one of: %s\n" "$pre" "$p" "$v" "$*" >&2
  return 1
}

claude_auth_mode() {
  # shellcheck disable=SC2086 # the enum list splits on purpose
  _cauth_read claude_auth. "${1:-}" oauth $CLAUDE_AUTH_MODES
}

runner_lock_for() {
  # shellcheck disable=SC2086 # the enum list splits on purpose
  _cauth_read runner_lock. "${1:-}" "" $RUNNER_LOCKS
}

# claude_auth_managed_guard (BH-9676) — rc 0 when no Claude Code managed-settings
# file sets `forceLoginMethod` or `forceLoginOrgUUID` at its top level; rc 1 and
# one stderr line naming the file and the key (never the value) otherwise. The
# CLI refuses ANTHROPIC_API_KEY when either key is set, so an api-key project
# stops here, before any model call. Files read: the managed-settings file and
# every *.json drop-in beside it (paths, not limits; the env overrides are for
# the tests). A file that is not valid JSON is decided by a plain grep, so a
# broken file that still names the key refuses too. No network.
claude_auth_managed_guard() {
  local f k hit
  for f in "${CLAUDE_MANAGED_SETTINGS_FILE:-/etc/claude-code/managed-settings.json}" \
           "${CLAUDE_MANAGED_SETTINGS_DIR:-/etc/claude-code/managed-settings.d}"/*.json; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    hit=""
    if jq -e . "$f" >/dev/null 2>&1; then
      hit=$(jq -r '[("forceLoginMethod","forceLoginOrgUUID") as $k | select(type == "object" and has($k)) | $k] | first // empty' "$f" 2>/dev/null)
    else
      for k in forceLoginMethod forceLoginOrgUUID; do
        grep -q "\"$k\"" "$f" 2>/dev/null && { hit="$k"; break; }
      done
    fi
    if [ -n "$hit" ]; then
      printf 'claude-auth: %s sets %s; the claude CLI blocks ANTHROPIC_API_KEY with it. Remove the key for an api-key project.\n' "$f" "$hit" >&2
      return 1
    fi
  done
  return 0
}

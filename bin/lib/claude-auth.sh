#!/bin/bash
# bin/lib/claude-auth.sh — HOW a project pays for Claude, and whether its runs
# are locked to Claude (BH-9334). Sourced, never executed. Defines functions only.
#
#   . bin/lib/claude-auth.sh
#   claude_auth_mode <project>  -> `oauth` or `api-key` on stdout, rc 0
#   runner_lock_for <project>   -> `claude` or an empty line on stdout, rc 0
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

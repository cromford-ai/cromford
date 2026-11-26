#!/bin/bash
# bin/lib/agent-cmd-limit.sh — arm the per-command time limit for one agent
# call (BH-9779). Sourced by bin/agent-call.sh, never executed.
#
#   acl_arm <stage> <project>
#     For stage plan, execute, review or fix: resolves AGENT_CMD_LIMIT_S,
#     AGENT_CMD_TAIL_LINES and AGENT_CMD_KILL_GRACE_S once (the lib lane
#     agent-cmd-limit, `_LG_KIND=libs lane_knob` in a subshell, else the env,
#     else the fallback named on each read) and exports them with
#     CLAUDE_CODE_SHELL_PREFIX=<root>/bin/agent-cmd-limit.sh, so every shell
#     command of the claude process runs under the limit.
#     Any other stage: nothing (QA and triage keep dev servers up longer).
#     Not armed, with one log line (stderr, and $BUILD/pipeline.log when it
#     exists): the limit row is 0 or not a whole number, the wrapper is not
#     executable, or the caller already set CLAUDE_CODE_SHELL_PREFIX (it is
#     never overridden). rc 0 always: a limit that cannot arm never stops a call.
#
# The root is ${HARNESS:-${H:-}} only (D43): with none, nothing is armed.
[ -n "${_ACL_LIB_LOADED:-}" ] && return 0
_ACL_LIB_LOADED=1

# _acl_knob <ENV> <fallback> <project> — a whole number: the row, else the env,
# else <fallback>.
_acl_knob() {
  local root="${HARNESS:-${H:-}}" v=""
  if [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
    # shellcheck source=/dev/null
    v=$( . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1 && _LG_KIND=libs lane_knob agent-cmd-limit "$1" "${3:-}" 2>/dev/null )
  fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s' "$v"
}

_acl_log() {
  local m="agent-cmd-limit: $1"
  echo "$m" >&2
  [ -n "${BUILD:-}" ] && [ -d "$BUILD" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [${PROJECT:-}/${KEY:-}] $m" >> "$BUILD/pipeline.log" 2>/dev/null
  return 0
}

acl_arm() {
  local stage="${1:-}" project="${2:-}" root="${HARNESS:-${H:-}}" wrap lim tn kg
  case "$stage" in plan|execute|review|fix) ;; *) return 0 ;; esac
  [ -n "$root" ] || { _acl_log "not armed for $stage: no harness root"; return 0; }
  wrap="$root/bin/agent-cmd-limit.sh"
  # A second attempt in the same agent-call process is already armed.
  [ "${CLAUDE_CODE_SHELL_PREFIX:-}" = "$wrap" ] && return 0
  if [ -n "${CLAUDE_CODE_SHELL_PREFIX:-}" ]; then
    _acl_log "not armed for $stage: the caller set CLAUDE_CODE_SHELL_PREFIX, which is kept"; return 0
  fi
  [ -x "$wrap" ] || { _acl_log "not armed for $stage: $wrap is not executable"; return 0; }
  lim=$(_acl_knob AGENT_CMD_LIMIT_S 1800 "$project")       # lib.agent-cmd-limit.agent_cmd_limit_s
  if [ "$lim" = 0 ] || ! [[ "$lim" =~ ^[1-9][0-9]*$ ]]; then
    _acl_log "not armed for $stage: AGENT_CMD_LIMIT_S is 0 (row lib.agent-cmd-limit.agent_cmd_limit_s)"; return 0
  fi
  tn=$(_acl_knob AGENT_CMD_TAIL_LINES 40 "$project")       # lib.agent-cmd-limit.agent_cmd_tail_lines
  kg=$(_acl_knob AGENT_CMD_KILL_GRACE_S 10 "$project")     # lib.agent-cmd-limit.agent_cmd_kill_grace_s
  export CLAUDE_CODE_SHELL_PREFIX="$wrap" AGENT_CMD_LIMIT_S="$lim" AGENT_CMD_TAIL_LINES="$tn" AGENT_CMD_KILL_GRACE_S="$kg"
  return 0
}

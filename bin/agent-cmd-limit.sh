#!/bin/bash
# bin/agent-cmd-limit.sh <command> | <program> <arg>... — one shell command of
# a build-stage agent, under a time limit (BH-9779).
#
# WHY. In BH-7921 one execute call ran 6,716 s on a Verify loop of 558 suite
# runs and ended rc 124 at the stage cap. The CLI moves a Bash command past its
# own timeout to the background and keeps it running, so nothing stopped that
# one command. bin/lib/agent-cmd-limit.sh (acl_arm, from bin/agent-call.sh) sets
# CLAUDE_CODE_SHELL_PREFIX to this file for the plan, execute, review and fix
# stages, and the CLI then runs `<this file> <command>` for each command.
#
# ARGS. One argument: it runs `bash -c "$1"`. Two or more: it runs "$@". None:
# rc 0, no output. AGENT_CMD_LIMIT_S not a positive whole number, no `timeout`
# binary, or no temp dir: the command runs unwrapped (exec). It never refuses a
# command.
#
# RUN. `timeout -k <grace> <limit> <cmd>`. GNU timeout makes the command its
# own process group and signals the whole group, so child processes end too.
# stdin is passed through. stdout and stderr stream as they come, each through
# tee to its own temp file. The wrapper waits for both tee processes, so no
# output is lost. A background child that the command left holding stdout or
# stderr is bounded by the same limit: when the limit passes with a tee still
# open, the command's process group gets SIGTERM, then SIGKILL after the grace.
#
# NORMAL PATH. The bytes on stdout and on stderr are exactly the command's,
# with no added line, and the rc is the command's. Hooks can run through the
# prefix too, and a hook's JSON on stdout must stay byte-exact.
#
# LIMIT PATH (the limit passed). After the streamed output, on stdout:
#   --- agent-cmd-limit: last <N> lines of output ---
#   <the last N lines of stdout, then of stderr>
#   agent-cmd-limit: this command was stopped at the <L> s limit (row ...). ...
# and rc 124. The agent session goes on to its next command.
#
# KNOBS (bin/lib/agent-cmd-limit.sh resolves them once per agent call and
# exports them): AGENT_CMD_LIMIT_S (row lib.agent-cmd-limit.agent_cmd_limit_s),
# AGENT_CMD_TAIL_LINES (row lib.agent-cmd-limit.agent_cmd_tail_lines, fallback
# 40), AGENT_CMD_KILL_GRACE_S (row lib.agent-cmd-limit.agent_cmd_kill_grace_s,
# fallback 10). Temp files are in ${TMPDIR:-/tmp} and are deleted on every exit.
set -u
[ $# -gt 0 ] || exit 0
LIM="${AGENT_CMD_LIMIT_S:-}"
_acl_unwrapped() { if [ $# -eq 1 ]; then exec bash -c "$1"; else exec "$@"; fi; }
[[ "$LIM" =~ ^[1-9][0-9]{0,6}$ ]] && command -v timeout >/dev/null 2>&1 || _acl_unwrapped "$@"
# lib.agent-cmd-limit.agent_cmd_tail_lines (catalog/lanes.d/_lib.agent-cmd-limit.json)
TN="${AGENT_CMD_TAIL_LINES:-40}"; [[ "$TN" =~ ^[1-9][0-9]{0,4}$ ]] || TN=40
# lib.agent-cmd-limit.agent_cmd_kill_grace_s (catalog/lanes.d/_lib.agent-cmd-limit.json)
KG="${AGENT_CMD_KILL_GRACE_S:-10}"; [[ "$KG" =~ ^[1-9][0-9]{0,3}$ ]] || KG=10
D=$(mktemp -d "${TMPDIR:-/tmp}/agent-cmd-limit.XXXXXX" 2>/dev/null) || _acl_unwrapped "$@"
trap 'rm -rf "$D"' EXIT
mkfifo "$D/o" "$D/e" 2>/dev/null || { rm -rf "$D"; trap - EXIT; _acl_unwrapped "$@"; }
[ $# -eq 1 ] && set -- bash -c "$1"

tee "$D/out" < "$D/o" & T1=$!
tee "$D/err" < "$D/e" >&2 & T2=$!
t0=$SECONDS
# fd 3 is the wrapper's stdin: a background job with no stdin redirection of
# its own would read /dev/null (no job control here).
exec 3<&0
timeout -k "$KG" "$LIM" "$@" <&3 > "$D/o" 2> "$D/e" 3<&- & TP=$!
exec 3<&-
wait "$TP"; RC=$?
# The drain: a child the command left can still hold the fifos open. It gets
# what is left of the limit, then its process group (timeout's) is ended.
STOPPED=0
if [ $((SECONDS - t0)) -ge "$LIM" ] && { [ "$RC" = 124 ] || [ "$RC" = 137 ]; }; then STOPPED=1; fi
left=$((LIM - (SECONDS - t0))); [ "$left" -ge 1 ] || left=1
# The watchdog ends its own sleep when it is told to stop, so no sleep is left.
(
  trap 'kill "$s" 2>/dev/null; exit 0' TERM
  sleep "$left" & s=$!; wait "$s"
  : > "$D/fired"; kill -TERM -- "-$TP" 2>/dev/null
  sleep "$KG" & s=$!; wait "$s"
  kill -KILL -- "-$TP" 2>/dev/null
) >/dev/null 2>&1 & WD=$!
wait "$T1" "$T2" 2>/dev/null
kill -TERM "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
# The watchdog fired: the command's leftovers held its output past the limit.
[ -e "$D/fired" ] && [ "$STOPPED" = 0 ] && { STOPPED=1; RC=124; }
[ "$STOPPED" = 1 ] || exit "$RC"
printf '\n--- agent-cmd-limit: last %s lines of output ---\n' "$TN"
tail -n "$TN" "$D/out" 2>/dev/null
[ -s "$D/err" ] && { printf -- '--- stderr ---\n'; tail -n "$TN" "$D/err" 2>/dev/null; }
printf 'agent-cmd-limit: this command was stopped at the %s s limit (row lib.agent-cmd-limit.agent_cmd_limit_s). Run one suite per command; the gate runs the wide selection.\n' "$LIM"
exit 124

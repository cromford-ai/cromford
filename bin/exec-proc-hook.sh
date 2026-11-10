#!/bin/bash
# bin/exec-proc-hook.sh — BH-9288: a Claude Code PostToolUse / PostToolUseFailure
# hook for the Bash tool of an EXECUTE session. bin/agent-call.sh loads it only
# for stage execute when bin/lib/rb/execute.sh set EXEC_PROC_TAG, and puts
# HARNESS_EXEC_TAG=<tag> on the claude line, so every Bash child carries it.
#
# Reads the hook JSON on stdin. Only the tool's RESPONSE is read (tool_response,
# error), never the command text, so `grep 137 x` cannot trigger it.
#   1. An out-of-memory signature (Exit code 137 not followed by a digit, heap
#      out of memory, FatalProcessOutOfMemory, Mark-Compact) and EXEC_PROC_DIR
#      is a directory: ep_snapshot writes $EXEC_PROC_DIR/oom-procs.txt. A later
#      OOM overwrites it (the newest decides, as ee_oom does).
#   2. THEN, on an OOM, a timeout ("Command timed out", "[timed out after",
#      tool_response.interrupted or is_interrupt true): ep_reap --strays ends
#      the process groups of orphaned test runners of this session. The
#      snapshot always comes first, so it shows what was alive at the kill.
# No HARNESS_EXEC_TAG: nothing. It prints nothing (no text goes back into the
# session) and exits 0 on every path. bin/lib/exec-procs.sh has the details.

payload=$(cat 2>/dev/null) || payload=""
[ -n "${HARNESS_EXEC_TAG:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
{
  _ep_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
  tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || tool=""
  [ "$tool" = Bash ] || exit 0
  text=$(jq -r '[.tool_response, .error] | map(select(. != null) | if type == "string" then . else tojson end) | join("\n")' <<<"$payload" 2>/dev/null) || text=""
  intr=$(jq -r 'if (.tool_response | type) == "object" and .tool_response.interrupted == true then 1 elif .is_interrupt == true then 1 else 0 end' <<<"$payload" 2>/dev/null) || intr=0
  sig=""
  if grep -q 'FatalProcessOutOfMemory' <<<"$text"; then sig=FatalProcessOutOfMemory
  elif grep -q 'heap out of memory' <<<"$text"; then sig="heap out of memory"
  elif grep -q 'Mark-Compact' <<<"$text"; then sig=Mark-Compact
  elif grep -Eq 'Exit code 137([^0-9]|$)' <<<"$text"; then sig="Exit code 137"
  fi
  timeout_hit=""
  [ "$intr" = 1 ] && timeout_hit=1
  grep -Eq 'Command timed out|\[timed out after' <<<"$text" && timeout_hit=1
  [ -n "$sig" ] || [ -n "$timeout_hit" ] || exit 0
  # shellcheck source=bin/lib/exec-procs.sh
  . "$_ep_dir/lib/exec-procs.sh" || exit 0
  if [ -n "$sig" ] && [ -n "${EXEC_PROC_DIR:-}" ] && [ -d "$EXEC_PROC_DIR" ]; then
    ep_snapshot "$EXEC_PROC_DIR/oom-procs.txt" "$sig"
  fi
  # The claude CLI: the highest ancestor that carries the tag.
  claude=""; p=$PPID; i=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$i" -lt 64 ]; do
    grep -qzxF -- "HARNESS_EXEC_TAG=$HARNESS_EXEC_TAG" "/proc/$p/environ" 2>/dev/null || break
    claude=$p
    p=$(awk '{ sub(/.*\) /, ""); print $2 }' "/proc/$p/stat" 2>/dev/null)
    i=$((i+1))
  done
  [ -n "$claude" ] && ep_reap "$HARNESS_EXEC_TAG" --strays "$claude"
} >/dev/null 2>&1
exit 0

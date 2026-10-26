#!/bin/bash
# bin/security-audit-launch.sh — start bin/security-audit.sh detached on the box
# that owns the project, and read its numbers back, so the console's run_script
# command (bin/cmd-run-script.sh, 300 s bound) can run a whole-repo audit with
# no ssh (BH-8375).
#
# usage: security-audit-launch.sh <project>
#        security-audit-launch.sh --status <project>
#   <project>   starts one runner in its own session: security-audit.sh <project>
#               --out $HARNESS/state/security-audit, with BUILD unset. Its output
#               goes to logs/security-audit-launch.log. It returns at once and
#               never waits on the run. The caps are the runner's settings rows
#               (security_audit.cap_usd, security_audit.cap_minutes); no arg here
#               can change them, and any other argv is a usage error.
#   --status    reads <out>/<project>/latest-summary.json and prints its numbers:
#               run, sha (12), stopped, cost_usd, duration_min, sandbox, counts,
#               validators. Never a finding, never REPORT.md.
# Refused (rc 3): a name that is not ^[a-z0-9._-]{1,64}$ or not a fleet.conf
# project; a start on a box with no ${SA_REPOS_DIR:-/root/repos}/<project>/.git.
# Running = the runner's lock <out>/.<project>.lock is held (flock -n probe, it
# never waits). A start while running prints already-running and starts nothing.
#
# Prints ONE JSON line: {result: started|already-running|refused|ok|none|failed, ...}.
# Exit: 0 started, already-running, ok or none; 1 failed (unreadable summary,
# spawn failed); 2 usage; 3 refused.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-/root/harness}"
OUT="$H/state/security-audit"

say() { # say <rc> <jq-program> [jq args...]
  local rc="$1" prog="$2"; shift 2
  jq -nc "$@" "$prog"
  exit "$rc"
}
usage() { say 2 '{result:"usage", reason:"usage: security-audit-launch.sh <project> | --status <project>"}'; }

STATUS=0
[ "${1:-}" = --status ] && { STATUS=1; shift; }
[ "$#" = 1 ] || usage
P="$1"
[[ "$P" =~ ^[a-z0-9._-]{1,64}$ ]] && "$SELF/fleet-conf.sh" --projects 2>/dev/null | grep -qxF -- "$P" \
  || say 3 '{result:"refused", reason:("\($p) is not a fleet.conf project"|.[0:200])}' --arg p "$P"

LOCK="$OUT/.$P.lock"
RUNNING=false
[ -e "$LOCK" ] && ! flock -n "$LOCK" true 2>/dev/null && RUNNING=true

if [ "$STATUS" = 1 ]; then
  S="$OUT/$P/latest-summary.json"
  [ -e "$S" ] || say 0 '{result:"none", project:$p, running:$r}' --arg p "$P" --argjson r "$RUNNING"
  J=$(jq -ec --argjson r "$RUNNING" 'select(type == "object") | {result:"ok", running:$r, project, run,
        sha:(.sha // "" | .[0:12]), stopped, cost_usd, duration_min, sandbox,
        counts:{confirmed:.counts.confirmed, needs_validation:.counts.needs_validation, rejected:.counts.rejected},
        validators:{findings:.validators.findings, ledger:.validators.ledger}}' "$S" 2>/dev/null) \
    || say 1 '{result:"failed", project:$p, reason:"latest-summary.json unreadable"}' --arg p "$P"
  printf '%s\n' "$J"
  exit 0
fi

[ -d "${SA_REPOS_DIR:-/root/repos}/$P/.git" ] \
  || say 3 '{result:"refused", reason:("this box has no checkout of \($p); send the command to project \($p) so the box that owns it runs it"|.[0:200])}' --arg p "$P"
[ "$RUNNING" = true ] && say 0 '{result:"already-running", project:$p}' --arg p "$P"

mkdir -p "$OUT" "$H/logs" || say 1 '{result:"failed", project:$p, reason:"cannot create state/security-audit or logs/"}' --arg p "$P"
# A subshell's background job is not a group leader, so setsid does not fork:
# the pid printed is the runner's own pid and its session id.
PID=$( ( env -u BUILD setsid "$SELF/security-audit.sh" "$P" --out "$OUT" \
           </dev/null >>"$H/logs/security-audit-launch.log" 2>&1 7>&- 9>&- &
         echo $! ) ) || PID=""
[[ "$PID" =~ ^[0-9]+$ ]] || say 1 '{result:"failed", project:$p, reason:"could not start bin/security-audit.sh"}' --arg p "$P"
say 0 '{result:"started", project:$p, pid:$pid, out:$o, log:"logs/security-audit-launch.log"}' \
  --arg p "$P" --argjson pid "$PID" --arg o "$OUT"

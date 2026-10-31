#!/bin/bash
# bin/pm-flesh-launch.sh <project> <idea-id> — BH-7260: start bin/pm-flesh.sh
# detached on the box that owns the project, so the idea page's FLESH OUT
# button can run a flesh-out through the console's run_script command
# (bin/cmd-run-script.sh, 300 s bound; a flesh-out takes up to
# pm.flesh_timeout_s, 900 s) with no ssh.
#
# The console sends {type: run_script, project: <p>, script:
# pm-flesh-launch.sh, args: [<p>, <idea-id>]}. The Pages proxy admits only that
# shape (console-ui/functions/_lib/pm-flesh-command.js), the hub forwards it to
# the owning box, and cmd-run-script.sh runs it only because
# catalog/run-script-allowlist.d/bh-7260-pm-flesh.json lists it.
#
# Checks, before anything starts (rc 3, result refused):
#   - <project> is ^[A-Za-z0-9._-]{1,64}$ and a fleet.conf project;
#   - <idea-id> is ^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$ (a roadmap idea id; no / and no
#     control character, a narrower set than pm-flesh.sh accepts).
# Any other argv is a usage error (rc 2). No --force: a re-run of a billed or
# failed run stays a person's CLI step.
#
# The product lock (locks/<project>-product.lock, held by run-product,
# pm-groom and pm-flesh) is probed with flock -n and never waited on. Held:
# result busy, rc 0, nothing starts. Else pm-flesh.sh starts in its own session
# with fd 7 and fd 9 closed; its output goes to logs/pm-flesh-launch.log and its
# outcome to logs/pm-flesh.log and the pm_runs row the idea page reads. A run
# that pm-flesh.sh finds already done or billed makes no model call (its own
# claim before the spend).
#
# Prints ONE JSON line: {result: started|busy|refused|usage|failed, ...}.
# Exit: 0 started or busy; 1 failed (could not start); 2 usage; 3 refused.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-/root/harness}"

say() { # say <rc> <jq-program> [jq args...]
  local rc="$1" prog="$2"; shift 2
  jq -nc "$@" "$prog"
  exit "$rc"
}

[ "$#" = 2 ] || say 2 '{result:"usage", reason:"usage: pm-flesh-launch.sh <project> <idea-id>"}'
P="$1"; ID="$2"
[[ "$P" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && "$SELF/fleet-conf.sh" --projects 2>/dev/null | grep -qxF -- "$P" \
  || say 3 '{result:"refused", reason:("\($p) is not a fleet.conf project"|.[0:200])}' --arg p "$P"
[[ "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$ ]] \
  || say 3 '{result:"refused", reason:"the idea id must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$"}'
[ -x "$SELF/pm-flesh.sh" ] || say 1 '{result:"failed", reason:"bin/pm-flesh.sh is not an executable file on this box"}'

mkdir -p "$H/logs" "$H/locks" || say 1 '{result:"failed", reason:"cannot create logs/ or locks/"}'
LOCK="$H/locks/$P-product.lock"
if [ -e "$LOCK" ] && ! flock -n "$LOCK" true 2>/dev/null; then
  say 0 '{result:"busy", project:$p, idea_id:$i, reason:"the product lock is held (a run-product cycle, a brief or a flesh-out is active); try again later"}' \
    --arg p "$P" --arg i "$ID"
fi

# A subshell's background job is not a group leader, so setsid does not fork:
# the pid printed is pm-flesh.sh's own pid.
PID=$( ( setsid "$SELF/pm-flesh.sh" "$P" "$ID" \
           </dev/null >>"$H/logs/pm-flesh-launch.log" 2>&1 7>&- 9>&- &
         echo $! ) ) || PID=""
[[ "$PID" =~ ^[0-9]+$ ]] || say 1 '{result:"failed", project:$p, reason:"could not start bin/pm-flesh.sh"}' --arg p "$P"
say 0 '{result:"started", project:$p, idea_id:$i, pid:$pid, log:"logs/pm-flesh.log"}' \
  --arg p "$P" --arg i "$ID" --argjson pid "$PID"

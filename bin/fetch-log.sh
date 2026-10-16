#!/bin/bash
# bin/fetch-log.sh <project> <which> <command_id>
#   Resolve one WHITELISTED log, tail it, and print the `log_tail` beat JSON on
#   stdout. Called by poll-commands.sh for the console's fetch_log command so
#   Mission Control can read a box's logs without anyone SSH-ing into it.
#
# bin/fetch-log.sh --path <which> [project]
#   Print just the resolved path (the pure resolver the tests exercise).
#
# SECURITY: `which` is a closed set of literals and NOTHING from the request is
# ever interpolated into a path. `triage` is the one variant whose filename
# depends on the request, so its project is matched against fleet.conf rather
# than trusted — a project the fleet does not run cannot address a file.
#
# A log that does not exist yet (cost.csv on a box that has never built,
# pipeline-health.log before the first finding) is reported as empty with
# missing:true, never as a failed command: an honestly empty pane beats an
# error the console has to guess about.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
CAP=16000   # bytes of tail shipped in one beat

valid_project() { # EXACT membership in fleet.conf, or the literal "hub"
  # Exact, because fleet-conf.sh's own row lookup is a REGEX: `project-1.os` would
  # match the project-1 row there and box-for.sh would happily route to that
  # box. Rejecting it here, before anything downstream sees it, closes that.
  # "hub" is the one non-project caller: the hub owns no project of its own but
  # holds the decisions log, the cost roll-up and pipeline-health.
  [ "$1" = hub ] && return 0
  [ -n "$1" ] || return 1
  "$(dirname "$0")/fleet-conf.sh" --projects 2>/dev/null | grep -qxF "$1"
}

resolve() { # resolve <which> <project> -> path on stdout, rc 1 if refused
  local which="$1" project="${2:-}"
  # The project is validated for EVERY which, not just the one that puts it in a
  # filename: it also picks the box the request is forwarded to and it lands in
  # the journal, so an unregistered project is a refusal either way.
  valid_project "$project" || return 1
  case "$which" in
    alerts)    echo "$HARNESS/logs/ALERTS.log" ;;
    pipeline)  echo "$HARNESS/logs/pipeline-health.log" ;;
    cost)      echo "$HARNESS/logs/cost.csv" ;;
    decisions) echo "$HARNESS/logs/decisions.log" ;;
    run_script) echo "$HARNESS/logs/run-script.log" ;;
    triage)
      [ "$project" = hub ] && return 1
      echo "$HARNESS/logs/$project.log" ;;
    *) return 1 ;;
  esac
}

if [ "${1:-}" = "--path" ]; then
  resolve "${2:-}" "${3:-}"
  exit $?
fi

PROJECT="${1:-}"; WHICH="${2:-}"; CID="${3:-}"

# Terminal beat for a request that will never produce a tail. The console pane
# is keyed on log:<cid>, and "the owning box is down" is exactly the moment
# someone is watching it — silence there is indistinguishable from a hung fetch.
if [ "$PROJECT" = "--error" ]; then
  shift; jq -nc --arg p "${1:-}" --arg w "${2:-}" --arg cid "${3:-}" --arg e "${4:-error}" \
    --arg ts "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
    '{kind:"log_tail",rkey:("log:"+$cid),command_id:$cid,project:$p,which:$w,
      content:"",truncated:false,missing:true,bytes:0,error:$e,ts:$ts}'
  exit 0
fi

JLOG="$HARNESS/logs/console-commands.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# Journal fields are sanitised, not quoted: these arrive from the console and a
# newline in one of them would let a caller forge whole journal lines.
jsafe() { printf %s "${1:-}" | tr -dc 'A-Za-z0-9_.:/-' | head -c 64; }
journal() { mkdir -p "$HARNESS/logs"
  echo "$(STAMP) fetch_log id=$(jsafe "$CID") project=$(jsafe "$PROJECT") which=$(jsafe "$WHICH") -> $1" >> "$JLOG"; }

[ -n "$CID" ] || { journal "refused: no command id"; exit 1; }
F=$(resolve "$WHICH" "$PROJECT") || { journal "REFUSED: not a whitelisted log/project"; exit 1; }

# REHYDRATE THE DECISIONS LOG (BH-436). It is a hub artifact that the wipe on
# 2026-09-15 (#388) took with it, and an empty pane is indistinguishable from a
# quiet week. Here in the main flow rather than inside resolve(), which is the
# pure --path resolver the tests call and which runs in a $(...) subshell — so
# --path stays a path lookup and never touches the network. No request when the
# file is already on disk; an outage leaves missing:true exactly as today.
if [ "$WHICH" = decisions ] && [ -r "$HARNESS/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
  log_rehydrate decisions "$F" 30 >/dev/null 2>&1 || true
fi

SIZE=0; MISSING=true
if [ -f "$F" ]; then MISSING=false; SIZE=$(wc -c < "$F" | tr -dc '0-9'); fi
TRUNC=false; [ "${SIZE:-0}" -gt "$CAP" ] && TRUNC=true

# jq does the string encoding — quotes, backslashes, newlines and tabs all live
# in real log lines, and hand-built JSON would hand the console an unparseable
# beat exactly when someone is trying to read a failure.
CONTENT=$(tail -c "$CAP" "$F" 2>/dev/null | jq -Rs . 2>/dev/null)
[ -n "$CONTENT" ] || CONTENT='""'

jq -nc --arg cid "$CID" --arg p "$PROJECT" --arg w "$WHICH" \
  --argjson c "$CONTENT" --argjson t "$TRUNC" --argjson m "$MISSING" \
  --argjson b "${SIZE:-0}" --arg ts "$(STAMP)" \
  '{kind:"log_tail",rkey:("log:"+$cid),command_id:$cid,project:$p,which:$w,
    content:$c,truncated:$t,missing:$m,bytes:$b,ts:$ts}'
journal "ok ${SIZE:-0}b truncated=$TRUNC missing=$MISSING"
exit 0

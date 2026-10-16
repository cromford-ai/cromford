#!/bin/bash
# bin/cmd-dispatch-issue.sh <project> <payload-json> <command_id> — the
# console's dispatch_issue command (BH-6737). Runs on the hub from
# bin/poll-commands.sh: the Fly pool exists only there.
#
# payload {issue: <positive integer>}. It moves an issue that is ALREADY
# queued for the pool to the front of the next spawn. It does not enqueue a
# build that triage did not admit. In this order, the first refusal stops it
# and nothing is written:
#   1. the project is a fleet.conf GitHub-issues board, the issue a positive
#      JSON integer;
#   2. flags/fly-pool-<p> exists (the pool is enabled);
#   3. KEY = <PREFIX>-<issue> (preplan_key_prefix);
#   4. hold_check: open, labelled ai-build, not held (unreadable is rc 1);
#   5. not already building: the build-key lock is free, no state/fly-pool
#      record carries the key, and the queue row is not `claimed`;
#   6. queued: the queue row is `queued`, or state/build-queue/<p>/<KEY>.json
#      exists (a queue outage with no file is rc 1, not a refusal).
# Then it writes the marker state/dispatch-now/<p>/<KEY> (bin/fly-pool.sh's
# hotfix_first spawns marked keys right after hotfixes), prunes markers older
# than 24 h, starts ONE bin/fly-pool.sh tick detached (fly-pool's own lock makes
# an overlapping tick a no-op; the marker still orders the next one), and
# waits up to CMD_DISPATCH_WAIT_S (default 20) for a pool record that names the
# key. machine_id is set only from such a record, else null.
#
# Prints ONE JSON line: {result, project, issue, key, machine_id, reason}.
# Exit 0 ok, 3 refused, 1 failed (retryable).
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
PROJECT="${1:-}"; PAYLOAD="${2:-}"; CID="${3:-}"
ISSUE=""; KEY=""

emit() { # emit <rc> <result> <reason> [machine_id]
  jq -nc --arg r "$2" --arg p "$PROJECT" --arg i "$ISSUE" --arg k "$KEY" --arg m "${4:-}" --arg why "${3:0:200}" \
    '{result:$r, project:$p}
     + (if $i == "" then {} else {issue:($i|tonumber)} end)
     + (if $k == "" then {} else {key:$k} end)
     + {machine_id:(if $m == "" then null else $m end), reason:$why}'
  exit "$1"
}

# 1. project and issue
[[ "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$PROJECT" != *..* ]] || emit 3 refused "bad project"
if ! PJS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null) || [ -z "${PJS//[[:space:]]/}" ]; then
  emit 1 failed "fleet-conf --projects could not be read; retry"
fi
grep -qxF -- "$PROJECT" <<<"$PJS" || emit 3 refused "$PROJECT is not a fleet.conf project"
SLUG=$("$H/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || emit 1 failed "fleet-conf $PROJECT repo could not be read"
BP=$("$H/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || emit 1 failed "fleet-conf $PROJECT board_prefix could not be read"
if [ "$BP" != "-" ] || ! [[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  emit 3 refused "$PROJECT is not a GitHub-issues board"
fi
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$PAYLOAD" || emit 3 refused "payload is not a JSON object"
ISSUE=$(jq -r 'if (.issue|type) == "number" and .issue == (.issue|floor) and .issue > 0 and .issue < 10000000000
               then (.issue|floor|tostring) else "" end' <<<"$PAYLOAD" 2>/dev/null)
[[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || { ISSUE=""; emit 3 refused "issue must be a positive JSON integer"; }

# 2. the pool is enabled
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || flag_file_on() { [ -f "$H/flags/$1-$2" ]; }
flag_file_on fly-pool "$PROJECT" || emit 3 refused "pool not enabled for $PROJECT (no flags/fly-pool-$PROJECT)"

# 3. the key
# shellcheck source=bin/lib/preplan-lib.sh
. "$H/bin/lib/preplan-lib.sh" 2>/dev/null || emit 1 failed "bin/lib/preplan-lib.sh not loaded"
PFX=$(preplan_key_prefix "$H" "$PROJECT") || emit 3 refused "no ticket key prefix in prompts/$PROJECT.md"
KEY="$PFX-$ISSUE"

# 4. open, ai-build, not held
# shellcheck source=bin/lib/hold.sh
. "$H/bin/lib/hold.sh" 2>/dev/null || emit 1 failed "bin/lib/hold.sh not loaded"
# shellcheck source=bin/lib/gh-app-auth.sh
. "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || true
HV=$(hold_check "$SLUG" "$ISSUE"); HRC=$?
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
HWHY=$(head -n 1 <<<"$HV" | cut -f2- | tr -d '\r')
case "$HRC" in
  0) ;;
  1) emit 3 refused "$KEY is held: $HWHY" ;;
  *) emit 1 failed "hold check unreadable: $HWHY" ;;
esac

# 5. not already building
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
QSTAT=""; QRC=1
if command -v queue_status >/dev/null 2>&1; then QSTAT=$(queue_status "$PROJECT" "$KEY" 2>/dev/null); QRC=$?; fi
preplan_held "$H/locks/build-key-$PROJECT-$KEY.lock" && emit 3 refused "already building: locks/build-key-$PROJECT-$KEY.lock is held"
for f in "$H/state/fly-pool/$PROJECT"/*.json; do
  case "${f##*/}" in .*) continue ;; esac
  [ -f "$f" ] || continue
  if [ "$(jq -r '.key // ""' "$f" 2>/dev/null)" = "$KEY" ]; then
    emit 3 refused "already building: pool record ${f##*/} carries $KEY" "$(jq -r '.machine // ""' "$f" 2>/dev/null)"
  fi
done
[ "$QRC" = 0 ] && [ "$QSTAT" = claimed ] && emit 3 refused "already building: the queue row for $KEY is claimed"

# 6. queued for the pool
if ! { [ "$QRC" = 0 ] && [ "$QSTAT" = queued ]; } && [ ! -f "$H/state/build-queue/$PROJECT/$KEY.json" ]; then
  case "$QRC" in
    0|2) emit 3 refused "$KEY is not queued for the pool (queue row: ${QSTAT:-none})" ;;
    *)   emit 1 failed "the build queue could not be read and no queue file names $KEY; retry" ;;
  esac
fi

# 7. the marker
MD="$H/state/dispatch-now/$PROJECT"
mkdir -p "$MD" || emit 1 failed "cannot create state/dispatch-now/$PROJECT"
find "$MD" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null
{ printf '%s %s\n' "$(date -u +%s)" "$(printf '%s' "$CID" | tr -dc 'A-Za-z0-9_.:-' | head -c 64)" > "$MD/.$KEY.tmp.$$" \
  && mv "$MD/.$KEY.tmp.$$" "$MD/$KEY"; } || { rm -f "$MD/.$KEY.tmp.$$"; emit 1 failed "cannot write the dispatch marker"; }

# 8. one tick, detached and never killed; fd 7/9 (the poller's locks) closed
( setsid "$H/bin/fly-pool.sh" "$PROJECT" </dev/null >/dev/null 2>&1 7>&- 9>&- & ) \
  || emit 1 failed "marked first, but the fly-pool tick did not start; the next cron tick reads the marker"

# 9. a bounded wait for the machine
WAIT="${CMD_DISPATCH_WAIT_S:-20}"
case "$WAIT" in ''|*[!0-9]*) WAIT=20 ;; esac
END=$(( $(date +%s) + WAIT ))
while :; do
  for f in "$H/state/fly-pool/$PROJECT"/*.json; do
    case "${f##*/}" in .*) continue ;; esac
    [ -f "$f" ] || continue
    if [ "$(jq -r '.key // ""' "$f" 2>/dev/null)" = "$KEY" ]; then
      M=$(jq -r '.machine // ""' "$f" 2>/dev/null)
      [ -n "$M" ] && emit 0 ok "marked first; fly-pool spawned $KEY on $M" "$M"
    fi
  done
  [ "$(date +%s)" -lt "$END" ] || break
  sleep 1
done
emit 0 ok "marked first; fly-pool tick started; no machine yet (a spawn takes minutes, or the tick lock was held)"

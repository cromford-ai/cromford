#!/bin/bash
# bin/roadmap-issue-sync.sh — BH-7267 (BH-7243.4): keep the state of the
# GitHub issues linked to roadmap ideas in sync. A hub lane, every 15 minutes
# (cron/lanes/744-roadmap-issue-sync.cron). It makes no model call.
#
# WHY. roadmap_links ties an idea to a filed issue (bin/roadmap-file.sh writes
# them; BH-7243.2 adds hand links). The roadmap board computes Now and Shipped
# from roadmap_links.issue_state, so that column must follow GitHub.
#
# ONE TICK:
#   1. lane_gate_or_exit / lane_env_apply roadmap-issue-sync. flock -n
#      locks/roadmap-issue-sync.lock.
#   2. GET /api/roadmap/links/stale: the links never seen or seen longer ago
#      than roadmap.issue_sync_stale_min, never-seen first, capped by
#      roadmap.issue_sync_batch (both settings rows, applied by the route).
#      A failed read: one log line, exit 0, no GitHub call.
#   3. Per distinct (repo, issue): ONE GET repos/<repo>/issues/<n>.
#        rc 0:  state open -> open; closed + state_reason completed ->
#               closed_completed; any other closed -> closed_other; then
#               PUT /api/roadmap/links/state. An unparseable body or an unknown
#               state: no issue_state write, a tried stamp, failed+=1.
#        410:   GitHub deleted the issue: closed_other, written as above.
#        rc 44: no issue_state write, a tried stamp, failed+=1.
#        rc 75: the loop stops. stopped=rate-limited on a rate limit (no
#               stamp: the issue is not at fault), else a tried stamp and
#               stopped=unverifiable.
#      A tried stamp is PUT /api/roadmap/links/state {tried:true}: it moves the
#      link to the back of the stale queue and keeps its issue_state. Without
#      it, one dead issue holds the head of the queue on every tick and no
#      other link is read again (BH-7267 refute review).
#   4. One summary line in logs/roadmap-issue-sync.log and on stdout:
#      read=<n> written=<n> failed=<n> stopped=<none|rate-limited|unverifiable>
#      written counts a PUT that answered 200 only.
#
# OFF: flags/lane-off-roadmap-issue-sync or bin/harness-ctl.sh off
# roadmap-issue-sync. Registry: catalog/lanes.d/roadmap-issue-sync.json.
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || exit 0
command -v _jobs_req >/dev/null 2>&1 && command -v gh_rest >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
# Through bin/gh-rest-shim when it is installed, else gh api direct.
if [ -x "$SELF/gh-rest-shim" ]; then gh() { "$SELF/gh-rest-shim" "$@"; }; fi

LOG="$H/logs/roadmap-issue-sync.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# rest <out-file> <method> <path> [args...]: one gh_rest call into a file (never
# a $( ), so GH_REST_STATUS survives); RC is its rc.
rest() { RC=0; GH_REST_STATUS=; GH_REST_REASON=; gh_rest "$2" "$3" "${@:4}" > "$1" 2>/dev/null || RC=$?; }
# tried <repo> <n>: stamp state_seen_at of a link whose read failed; issue_state stays.
tried() {
  _jobs_req PUT /api/roadmap/links/state "$(jq -nc --arg r "$1" --argjson n "$2" '{repo:$r, issue:$n, tried:true}')" >/dev/null \
    && [ "${JOBS_HTTP:-}" = 200 ] || log "$1#$2: PUT /api/roadmap/links/state tried failed (http ${JOBS_HTTP:-none})"
}

tick() {
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit roadmap-issue-sync
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply roadmap-issue-sync
  exec 9>"$H/locks/roadmap-issue-sync.lock" || exit 0
  flock -n 9 || exit 0
  mkdir -p "$H/state/roadmap-issue-sync" 2>/dev/null
  TMPD=$(mktemp -d "$H/state/roadmap-issue-sync/tick.XXXXXX") || exit 0
  # shellcheck disable=SC2064
  trap "case '$TMPD' in '$H/state/roadmap-issue-sync/'?*) rm -rf '$TMPD' ;; esac" EXIT

  local resp rc pairs repo n f state put nread=0 written=0 failed=0 stopped=none
  resp=$(_jobs_req GET /api/roadmap/links/stale); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.links | type) == "array"' <<<"$resp" >/dev/null 2>&1; then
    log "GET /api/roadmap/links/stale failed (http ${JOBS_HTTP:-none}); no GitHub read this tick"
    exit 0
  fi
  # One GET per distinct (repo, issue), in the route's order (never seen first).
  pairs=$(jq -r 'reduce (.links[] | select((.repo | type) == "string" and (.issue | tostring | test("^[0-9]+$")))
    | "\(.repo) \(.issue)") as $x ([]; if any(.[]; . == $x) then . else . + [$x] end) | .[]' <<<"$resp" 2>/dev/null)
  f="$TMPD/issue.json"
  while read -r repo n <&3; do
    [ -n "$repo" ] || continue
    rest "$f" GET "repos/$repo/issues/$n"
    nread=$((nread + 1)); state=""
    case "$RC" in
      0) state=$(jq -r 'if .state == "open" then "open"
           elif .state == "closed" and .state_reason == "completed" then "closed_completed"
           elif .state == "closed" then "closed_other" else "" end' "$f" 2>/dev/null)
         if [ -z "$state" ]; then
           log "$repo#$n: no known state in the answer; issue_state not written"
           tried "$repo" "$n"; failed=$((failed + 1)); continue
         fi ;;
      44) log "$repo#$n: GitHub answered 404; issue_state not written"
          tried "$repo" "$n"; failed=$((failed + 1)); continue ;;
      *) if [ "${GH_REST_STATUS:-}" = 410 ]; then
           log "$repo#$n: GitHub answered 410 (the issue is deleted); closed_other"
           state=closed_other
         else
           if [ "${GH_REST_REASON:-}" = rate-limit ]; then stopped=rate-limited; else stopped=unverifiable; tried "$repo" "$n"; fi
           log "$repo#$n: http ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}; the loop stops"
           break
         fi ;;
    esac
    put=$(jq -nc --arg r "$repo" --argjson n "$n" --arg s "$state" '{repo:$r, issue:$n, issue_state:$s}')
    _jobs_req PUT /api/roadmap/links/state "$put" >/dev/null; rc=$?
    if [ "$rc" = 0 ] && [ "${JOBS_HTTP:-}" = 200 ]; then written=$((written + 1))
    else log "$repo#$n: PUT /api/roadmap/links/state failed (http ${JOBS_HTTP:-none})"; failed=$((failed + 1)); fi
  done 3<<<"$pairs"
  log "read=$nread written=$written failed=$failed stopped=$stopped"
  echo "read=$nread written=$written failed=$failed stopped=$stopped"
}

case "${1:-}" in
  '') tick ;;
  *) echo "usage: roadmap-issue-sync.sh" >&2; exit 2 ;;
esac
exit 0

#!/bin/bash
# merge-queue-red-audit.sh [--days N] — list every PR the box merge queue
# landed in the last N days (default 7) whose head CI was not `success` at
# merge time (BH-6428). Read-only: it writes nothing anywhere.
#
# Source of "landed by the merge queue": the coordination DB's merge_queue rows
# with status `landed`. bin/merge-queue.sh is the only writer of that status
# (MQROW … landed); the conductor records its merges under ledger kind `merge`.
# A row is in the window when its updated_at is.
#
# Per PR: GET repos/<slug>/pulls/<n> (head.sha, merged_at), then
# GET repos/<slug>/actions/runs?head_sha=<sha>. Runs created after merged_at
# are dropped; the latest run per workflow name is kept (the reduction
# mc_ci_state uses); cancelled, skipped, neutral and timed_out are dropped.
# The verdict at merge time:
#   failure     a kept run completed failure (or startup_failure) by merged_at
#   pending     a kept run had not completed by merged_at
#   none        no run is left
#   success     every kept run completed success by merged_at
#   not-merged  GitHub says the PR has no merged_at
#   unreadable  a GitHub read failed
#
# Output: one TSV line per PR that is not `success`:
#   project  pr  slug  head8  merged_at  verdict
# then one count line:
#   merge-queue-red-audit: <k> of <m> merge-queue landings in <N>d had head CI
#   not success at merge time (unreadable=<u>, not_merged=<x>, incomplete=<projects|none>)
# k counts failure, pending and none. `incomplete` names each project whose
# read returned the route's 500-row cap: the route sorts oldest first, so the
# newest landings of that project are not in this audit.
#
# rc 0 the report was produced; rc 75 a merge_queue read failed (no count line).
# Clock seam for tests: MQ_AUDIT_NOW (epoch seconds).
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

DAYS=7
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "usage: merge-queue-red-audit.sh [--days N]" >&2; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*|0) echo "merge-queue-red-audit: --days wants a positive whole number, got '$DAYS'" >&2; exit 2 ;; esac

for f in bin/jobs-client.sh bin/lib/gh-rest.sh; do
  [ -r "$H/$f" ] || { echo "merge-queue-red-audit: missing $H/$f — nothing was read" >&2; exit 75; }
done
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh"

NOW="${MQ_AUDIT_NOW:-$(date -u +%s)}"
CUTOFF=$(date -u -d "@$((NOW - DAYS * 86400))" +%Y-%m-%dT%H:%M:%SZ)
CAP=500

PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
[ -n "$PROJECTS" ] || { echo "merge-queue-red-audit: fleet.conf lists no project — nothing to audit" >&2; exit 75; }

ROWS=""; INCOMPLETE=""
for p in $PROJECTS; do
  resp=$(_jobs_req GET "/api/merge-queue?project=$p&status=landed&limit=$CAP"); rc=$?
  if [ "$rc" != 0 ]; then
    echo "merge-queue-red-audit: the merge_queue rows of $p could not be read (rc $rc) — no report" >&2
    exit 75
  fi
  n=$(jq -r '(.merge_queue // []) | length' <<<"$resp" 2>/dev/null) || n=""
  case "$n" in ''|*[!0-9]*) echo "merge-queue-red-audit: the merge_queue answer for $p is not a row list — no report" >&2; exit 75 ;; esac
  [ "$n" -ge "$CAP" ] && INCOMPLETE="${INCOMPLETE:+$INCOMPLETE,}$p"
  ROWS+=$(jq -r --arg c "$CUTOFF" '.merge_queue[]? | select((.updated_at // "") >= $c)
          | [.project, (.pr | tostring), (.repo // "-")] | @tsv' <<<"$resp" 2>/dev/null)$'\n'
done

RUNS_JQ='[.workflow_runs[]? | select((.created_at // "") <= $m)
   | {n: ((.name // .workflow_id // "?") | tostring), t: ((.run_started_at // .created_at) // ""),
      a: (.run_attempt // 1), s: (.status // ""), c: (.conclusion // ""), u: (.updated_at // "")}]
 | group_by(.n) | map(sort_by(.t, .a) | last)
 | map(if .s == "completed" and .u <= $m then .c else "incomplete" end)
 | map(select(. != "cancelled" and . != "skipped" and . != "neutral" and . != "timed_out"))
 | if length == 0 then "none"
   elif any(.[]; . == "failure" or . == "startup_failure") then "failure"
   elif all(.[]; . == "success") then "success"
   else "pending" end'

M=0; K=0; U=0; X=0
while IFS=$'\t' read -r proj pr repo; do
  [ -n "${pr:-}" ] || continue
  M=$((M + 1))
  slug="$repo"
  case "$slug" in ''|-|null) slug=$("$H/bin/fleet-conf.sh" "$proj" repo 2>/dev/null) ;; esac
  head=""; merged=""
  if [ -z "$slug" ]; then
    verdict=unreadable
  elif ! gh_rest_var pj GET "repos/$slug/pulls/$pr"; then
    verdict=unreadable
  else
    head=$(jq -r '.head.sha // ""' <<<"$pj" 2>/dev/null)
    merged=$(jq -r '.merged_at // ""' <<<"$pj" 2>/dev/null)
    if [ -z "$merged" ]; then
      verdict=not-merged
    elif [ -z "$head" ] || ! gh_rest_var runs GET "repos/$slug/actions/runs?head_sha=$head&per_page=50"; then
      verdict=unreadable
    else
      verdict=$(jq -r --arg m "$merged" "$RUNS_JQ" <<<"$runs" 2>/dev/null) || verdict=""
      [ -n "$verdict" ] || verdict=unreadable
    fi
  fi
  case "$verdict" in
    success) continue ;;
    unreadable) U=$((U + 1)) ;;
    not-merged) X=$((X + 1)) ;;
    *) K=$((K + 1)) ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$proj" "$pr" "${slug:--}" "${head:0:8}" "${merged:--}" "$verdict"
done <<<"$ROWS"

echo "merge-queue-red-audit: $K of $M merge-queue landings in ${DAYS}d had head CI not success at merge time (unreadable=$U, not_merged=$X, incomplete=${INCOMPLETE:-none})"
exit 0

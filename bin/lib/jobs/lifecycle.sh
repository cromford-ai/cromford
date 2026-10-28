#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/lifecycle.sh — BH-8731 (lifecycle 1/6): the ticket lifecycle
# verbs over worker/jobs/src/routes/ticket-lifecycle.js. Sourced by the
# bin/jobs-client.d/bh-8731-lifecycle-*.sh verbs (not a JC_MODULES module), and
# by any lane that sources bin/jobs-client.sh first; never run.
#
# lifecycle_transition <project> <ticket_key> <to_phase> <actor> <reason> [pr] [question]
#   POST /api/lifecycle/transition {project, ticket_key, to_phase, actor,
#   reason, pr?, question?}. pr is sent as a number, and only when given;
#   question only when given. The worker decides legality and ownership.
# lifecycle_stuck [project]
#   GET /api/lifecycle/stuck[?project=]: the rows past their phase threshold.
#
# Return codes, both verbs (the transport's own map, bin/lib/jobs/req.sh):
#   0  200: the body is on stdout
#   9  409 (illegal move, wrong owner, stale): the body is on stdout
#   2  404 (no build_queue row for that ticket, or a worker without the route)
#   1  transport, 5xx, 400 or no coordination DB configured
#   3  bad arguments: one usage line on stderr, no request sent

_lifecycle_rc() { # _lifecycle_rc <rc of _jobs_req>
  case "$1" in 0|9|2) return "$1" ;; *) return 1 ;; esac
}

lifecycle_transition() {
  if [ $# -lt 5 ] || [ $# -gt 7 ] || [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] \
    || { [ -n "${6:-}" ] && ! [[ $6 =~ ^[1-9][0-9]{0,15}$ ]]; }; then
    echo "usage: lifecycle-transition <project> <ticket_key> <to_phase> <actor> <reason> [pr] [question]" >&2
    return 3
  fi
  local body
  body=$(jq -nc --arg p "$1" --arg k "$2" --arg to "$3" --arg a "$4" --arg r "$5" \
    --arg pr "${6:-}" --arg q "${7-}" --arg hasq "${7+1}" \
    '{project:$p, ticket_key:$k, to_phase:$to, actor:$a, reason:$r}
     + (if $pr == "" then {} else {pr:($pr|tonumber)} end)
     + (if $hasq == "1" then {question:$q} else {} end)' 2>/dev/null) || return 1
  [ -n "$body" ] || return 1
  _jobs_req POST /api/lifecycle/transition "$body"
  _lifecycle_rc $?
}

lifecycle_stuck() {
  if [ $# -gt 1 ]; then
    echo "usage: lifecycle-stuck [project]" >&2
    return 3
  fi
  local path=/api/lifecycle/stuck p
  if [ -n "${1:-}" ]; then
    p=$(jq -rn --arg v "$1" '$v|@uri') || return 1
    path="$path?project=$p"
  fi
  _jobs_req GET "$path"
  _lifecycle_rc $?
}

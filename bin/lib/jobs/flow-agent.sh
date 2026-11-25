#!/bin/bash
# bin/lib/jobs/flow-agent.sh — the shell client of the flow agent's D1 routes
# (worker/jobs/src/routes/flow-agent.js, BH-9924 slice BH-9956). Sourced AFTER
# bin/jobs-client.sh (it calls _jobs_req, _jobs_req_file and setting_get), never
# run. It is not in JC_MODULES: bin/flow-agent.sh sources it itself. No output
# and no side effect at source time, `set -u` safe.
#
# THE RC MAP is _jobs_req's, unchanged: 0 = 2xx, 9 = 409, 2 = 404, 1 = outage
# (a transport failure, a 5xx, a timeout, no secret). A FAILED READ PRINTS
# NOTHING, never `0` (D9/D11): fa_count24h prints the count only on rc 0.
#
#   fa_decision_key <project> <KEY> <code> <episode> [would]  sha256 hex of p|KEY|code|episode[|would]
#   fa_claim  <key> <project> <ticket> <code> <action> <episode> <outcome> <before>   rc 0 | 9 | 1
#   fa_record <key> <outcome> <after> <detail>                                       rc 0 | 9 | 2 | 1
#   fa_count24h <project> <ticket>        prints the count on rc 0; nothing on any other rc
#   fa_waiting_put <project> <rows-json-file>  the file holds the rows ARRAY  rc 0 | 1
#   fa_mode <project>                     act | log (no row = log, junk = log); rc 1 prints nothing
#   fa_nudge <owner/repo> <KEY> <episode> <reason>   rc 0 inserted | 9 already nudged | 1 outage
#   fa_knob <key> <fallback>              the settings row if it is a whole number, else the fallback

fa_decision_key() {
  local s="${1:-}|${2:-}|${3:-}|${4:-}"
  [ "${5:-}" = would ] && s="$s|would"
  printf '%s' "$s" | sha256sum | cut -d' ' -f1
}

fa_claim() {
  local body out rc
  body=$(jq -nc --arg k "${1:-}" --arg p "${2:-}" --arg t "${3:-}" --arg c "${4:-}" --arg a "${5:-}" \
    --arg e "${6:-}" --arg o "${7:-claimed}" --arg b "${8:-}" --arg box "${JOBS_BOX:-}" \
    '{decision_key:$k, project:$p, ticket_key:$t, code:$c, action:$a, episode:$e, outcome:$o}
     + (if $b == "" then {} else {before:$b} end) + (if $box == "" then {} else {box:$box} end)' 2>/dev/null) || return 1
  out=$(_jobs_req POST /api/flow-agent/claim "$body"); rc=$?
  case "$rc" in
    0|9) printf '%s' "$out"; return "$rc" ;;
    *) return 1 ;;   # a 404 here is a worker without the route: an outage, never "claimed"
  esac
}

fa_record() {
  local body out rc
  body=$(jq -nc --arg k "${1:-}" --arg o "${2:-}" --arg a "${3:-}" --arg d "${4:-}" \
    '{decision_key:$k, outcome:$o} + (if $a == "" then {} else {after:$a} end) + (if $d == "" then {} else {detail:$d} end)' 2>/dev/null) || return 1
  out=$(_jobs_req POST /api/flow-agent/record "$body"); rc=$?
  case "$rc" in
    0|9) printf '%s' "$out"; return "$rc" ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

fa_count24h() {
  local p="${1:-}" t="${2:-}" out rc n
  case "$p$t" in ''|*[!A-Za-z0-9._#-]*) return 1 ;; esac
  out=$(_jobs_req GET "/api/flow-agent/count?project=$p&ticket=${t//#/%23}"); rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 2 ] && return 1; return "$rc"; }
  n=$(jq -r '.count // empty' <<<"$out" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

fa_waiting_put() {
  local p="${1:-}" rows="${2:-}" body rc
  [ -n "$p" ] && [ -r "$rows" ] || return 1
  body=$(mktemp "${TMPDIR:-/tmp}/fa-waiting.XXXXXX") || return 1
  if ! jq -c --arg p "$p" 'if type == "array" then {project:$p, rows:.} else error("rows is not an array") end' "$rows" > "$body" 2>/dev/null; then
    rm -f "$body"; return 1
  fi
  _jobs_req_file PUT /api/flow-agent/waiting "$body" >/dev/null; rc=$?
  rm -f "$body"
  [ "$rc" = 0 ] && return 0
  return 1
}

fa_mode() {
  local v rc
  v=$(setting_get "flow_agent.project.${1:-}.mode"); rc=$?
  case "$rc" in
    0) case "$v" in act|log) printf '%s\n' "$v" ;; *) printf 'log\n' ;; esac; return 0 ;;
    2) printf 'log\n'; return 0 ;;
    *) return 1 ;;
  esac
}

fa_nudge() {
  local repo="${1:-}" key="${2:-}" ep="${3:-}" reason="${4:-}" dd lk body out rc ins
  [ -n "$repo" ] && [ -n "$key" ] && [ -n "$ep" ] || return 1
  lk=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  dd="flow:$lk:$(printf '%s' "$ep" | sha256sum | cut -c1-12)"
  dd="${dd:0:64}"
  case "$dd" in *[!a-z0-9:#-]*) return 1 ;; esac
  body=$(jq -nc --arg r "$repo" --arg k "$key" --arg why "$reason" --arg d "$dd" \
    '{repo:$r, key:(if ($k | test("^[0-9]+$")) then ($k | tonumber) else $k end), reason:$why, dedupe:$d}' 2>/dev/null) || return 1
  out=$(_jobs_req POST /api/wakes/nudge "$body"); rc=$?
  case "$rc" in
    0) ins=$(jq -r '.inserted // empty' <<<"$out" 2>/dev/null)
       case "$ins" in 1) return 0 ;; 0) return 9 ;; *) return 1 ;; esac ;;
    9) return 9 ;;
    *) return 1 ;;
  esac
}

fa_knob() {
  local v rc
  v=$(setting_get "${1:-}"); rc=$?
  if [ "$rc" = 0 ] && [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s\n' "$v"; else printf '%s\n' "${2:-}"; fi
}

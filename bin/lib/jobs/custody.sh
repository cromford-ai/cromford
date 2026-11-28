#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/custody.sh — BH-9554 (custody C0): the ONE write path for ticket
# custody, over worker/jobs/src/routes/custody.js. Sourced by
# bin/jobs-client.d/bh-9554-custody.sh (not a JC_MODULES module), and by any
# lane that sources bin/jobs-client.sh first; never run. docs/CUSTODY.md is
# the contract.
#
# custody_claim   <project> <ticket> <lane> <state> <next_action> [opts]
#                 opts: --lease-s N --deadline-min N | --deadline-at ISO --pr N --evidence TEXT
# custody_renew   <project> <ticket> <lane> [--lease-s N]
# custody_release <project> <ticket> <lane> <next_action> [--deadline-min N | --deadline-at ISO] [--evidence TEXT]
# custody_next    <project> <ticket> <lane> <next_action> [--state S] [--deadline-min N | --deadline-at ISO] [--pr N] [--evidence TEXT]
# custody_settle  <project> <ticket> <actor> <merged|closed> [--evidence TEXT]
# custody_act     <project> <ticket> <actor> <expect_attempt> <action> <why> <result> <next_action>
#                 [--deadline-min N | --deadline-at ISO] [--ladder-rung N]
# custody_due     [limit]
# custody_row     <project> <ticket>
# custody_gaps    [project]
#
# Return codes, every verb:
#   0  200 with ok:true: the body is on stdout
#   9  409 (held, not_owner, stale, settled): the body is on stdout. A refusal
#      is a correct answer: no alert
#   2  404 (no custody row for that ticket): no alert
#   1  FAILS LOUD: transport, 5xx, 400, a 200 without ok:true, no JOBS_URL or
#      no HARNESS_SECRET. One alert line ($HARNESS/bin/alert-line.sh --id
#      custody-unreachable-<project>; $JOBS_HARNESS when HARNESS is unset) and
#      one stderr line per failed call.
#      There is no file fallback and no retry here (the transport retries a
#      transport error once). The caller must stop its transition.
#   3  bad arguments: one usage line on stderr, no request sent
#
# The transport's own once-a-day ALERTS line is off for these calls
# (JOBS_ALERT=0), so one failed call is one alert.

# _custody_fail <verb> <project> <ticket> <lane> <status word>
_custody_fail() {
  local p="${2:-fleet}" h="${HARNESS:-${JOBS_HARNESS:-}}"
  local text="[custody/$p] $1 ${3:--} by ${4:--} failed: ${5:-unknown}. The jobs endpoint did not take the transition."
  echo "custody: $text" >&2
  # No harness root: the stderr line above is the only signal (BH-2613: a
  # bin/lib file never builds a path from an empty root).
  if [ -n "$h" ] && [ -x "$h/bin/alert-line.sh" ]; then
    if [ -n "${2:-}" ]; then
      "$h/bin/alert-line.sh" --id "custody-unreachable-$p" --project "$p" "$text" >/dev/null 2>&1
    else
      "$h/bin/alert-line.sh" --id "custody-unreachable-$p" "$text" >/dev/null 2>&1
    fi
  fi
  return 0
}

# _custody_call <verb> <project> <ticket> <lane> <method> <path> [body]
#   One request. Prints the body on 0 and 9. Maps the rc as the header says.
_custody_call() {
  local verb="$1" p="$2" k="$3" l="$4" method="$5" path="$6" body="${7:-}" sf out rc word
  sf=$(mktemp "${TMPDIR:-/tmp}/custody-status.XXXXXX" 2>/dev/null) || { _custody_fail "$verb" "$p" "$k" "$l" mktemp-failed; return 1; }
  out=$(JOBS_ALERT=0 JOBS_STATUS_FILE="$sf" _jobs_req "$method" "$path" "$body")
  rc=$?
  word=$(head -c 64 "$sf" 2>/dev/null)
  rm -f "$sf"
  case "$rc" in
    0)
      if jq -e '.ok == true' >/dev/null 2>&1 <<<"$out"; then printf '%s' "$out"; return 0; fi
      _custody_fail "$verb" "$p" "$k" "$l" "${word:-http=200} body without ok:true"; return 1 ;;
    9) printf '%s' "$out"; return 9 ;;
    2) return 2 ;;
    *) _custody_fail "$verb" "$p" "$k" "$l" "${word:-no-answer}"; return 1 ;;
  esac
}

# _custody_opts <allowed> <args...> — the --opts as one JSON object on stdout.
#   <allowed> is a space list of option names. rc 3 on an unknown option, a
#   missing value or a value of the wrong shape.
_custody_opts() {
  local allowed=" $1 " o="{}" k v
  shift
  while [ $# -gt 0 ]; do
    k="${1#--}"
    [[ $1 == --* ]] && [[ $allowed == *" $k "* ]] && [ $# -ge 2 ] || return 3
    v="$2"; shift 2
    case "$k" in
      lease-s|deadline-min|pr|ladder-rung)
        [[ $v =~ ^[0-9]{1,15}$ ]] || return 3
        o=$(jq -c --arg k "${k//-/_}" --argjson v "$((10#$v))" '. + {($k): $v}' <<<"$o") || return 3 ;;
      *)
        [ -n "$v" ] || return 3
        o=$(jq -c --arg k "${k//-/_}" --arg v "$v" '. + {($k): $v}' <<<"$o") || return 3 ;;
    esac
  done
  printf '%s' "$o"
}
_custody_usage() { echo "usage: custody $*" >&2; return 3; }
_custody_need() { # _custody_need <n> <args...>: rc 0 when the first n args are non-empty
  local n="$1" i; shift
  [ $# -ge "$n" ] || return 1
  for ((i = 1; i <= n; i++)); do [ -n "${!i}" ] || return 1; done
}

custody_claim() {
  local U="claim <project> <ticket> <lane> <state> <next_action> [--lease-s N] [--deadline-min N|--deadline-at ISO] [--pr N] [--evidence TEXT]"
  _custody_need 5 "$@" || { _custody_usage "$U"; return 3; }
  local opts body
  opts=$(_custody_opts "lease-s deadline-min deadline-at pr evidence" "${@:6}") || { _custody_usage "$U"; return 3; }
  body=$(jq -nc --arg p "$1" --arg k "$2" --arg l "$3" --arg s "$4" --arg n "$5" --argjson o "$opts" \
    '{project:$p, ticket:$k, lane:$l, state:$s, next_action:$n} + $o') || return 1
  _custody_call claim "$1" "$2" "$3" POST /api/custody/claim "$body"
}

custody_renew() {
  local U="renew <project> <ticket> <lane> [--lease-s N]"
  _custody_need 3 "$@" || { _custody_usage "$U"; return 3; }
  local opts body
  opts=$(_custody_opts "lease-s" "${@:4}") || { _custody_usage "$U"; return 3; }
  body=$(jq -nc --arg p "$1" --arg k "$2" --arg l "$3" --argjson o "$opts" '{project:$p, ticket:$k, lane:$l} + $o') || return 1
  _custody_call renew "$1" "$2" "$3" POST /api/custody/renew "$body"
}

custody_release() {
  local U="release <project> <ticket> <lane> <next_action> [--deadline-min N|--deadline-at ISO] [--evidence TEXT]"
  _custody_need 4 "$@" || { _custody_usage "$U"; return 3; }
  local opts body
  opts=$(_custody_opts "deadline-min deadline-at evidence" "${@:5}") || { _custody_usage "$U"; return 3; }
  body=$(jq -nc --arg p "$1" --arg k "$2" --arg l "$3" --arg n "$4" --argjson o "$opts" \
    '{project:$p, ticket:$k, lane:$l, next_action:$n} + $o') || return 1
  _custody_call release "$1" "$2" "$3" POST /api/custody/release "$body"
}

custody_next() {
  local U="next <project> <ticket> <lane> <next_action> [--state S] [--deadline-min N|--deadline-at ISO] [--pr N] [--evidence TEXT]"
  _custody_need 4 "$@" || { _custody_usage "$U"; return 3; }
  local opts body
  opts=$(_custody_opts "state deadline-min deadline-at pr evidence" "${@:5}") || { _custody_usage "$U"; return 3; }
  body=$(jq -nc --arg p "$1" --arg k "$2" --arg l "$3" --arg n "$4" --argjson o "$opts" \
    '{project:$p, ticket:$k, lane:$l, next_action:$n} + $o') || return 1
  _custody_call next "$1" "$2" "$3" POST /api/custody/next "$body"
}

custody_settle() {
  local U="settle <project> <ticket> <actor> <merged|closed> [--evidence TEXT]"
  _custody_need 4 "$@" || { _custody_usage "$U"; return 3; }
  local opts body
  opts=$(_custody_opts "evidence" "${@:5}") || { _custody_usage "$U"; return 3; }
  body=$(jq -nc --arg p "$1" --arg k "$2" --arg a "$3" --arg s "$4" --argjson o "$opts" \
    '{project:$p, ticket:$k, actor:$a, state:$s} + $o') || return 1
  _custody_call settle "$1" "$2" "$3" POST /api/custody/settle "$body"
}

custody_act() {
  local U="act <project> <ticket> <actor> <expect_attempt> <action> <why> <result> <next_action> [--deadline-min N|--deadline-at ISO] [--ladder-rung N]"
  _custody_need 8 "$@" && [[ $4 =~ ^[0-9]{1,15}$ ]] || { _custody_usage "$U"; return 3; }
  local opts body
  opts=$(_custody_opts "deadline-min deadline-at ladder-rung" "${@:9}") || { _custody_usage "$U"; return 3; }
  body=$(jq -nc --arg p "$1" --arg k "$2" --arg a "$3" --argjson e "$((10#$4))" --arg ac "$5" --arg w "$6" \
    --arg r "$7" --arg n "$8" --argjson o "$opts" \
    '{project:$p, ticket:$k, actor:$a, expect_attempt:$e, action:$ac, why:$w, result:$r, next_action:$n} + $o') || return 1
  _custody_call act "$1" "$2" "$3" POST /api/custody/act "$body"
}

custody_due() {
  if [ $# -gt 1 ] || { [ -n "${1:-}" ] && ! [[ $1 =~ ^[1-9][0-9]{0,5}$ ]]; }; then
    _custody_usage "due [limit]"; return 3
  fi
  local path=/api/custody/due
  [ -z "${1:-}" ] || path="$path?limit=$1"
  _custody_call due "" "" custodian GET "$path"
}

custody_row() {
  _custody_need 2 "$@" && [ $# -eq 2 ] || { _custody_usage "row <project> <ticket>"; return 3; }
  local p k
  p=$(jq -rn --arg v "$1" '$v|@uri') && k=$(jq -rn --arg v "$2" '$v|@uri') || return 1
  _custody_call row "$1" "$2" "" GET "/api/custody/row?project=$p&ticket=$k"
}

custody_gaps() {
  [ $# -le 1 ] || { _custody_usage "gaps [project]"; return 3; }
  local path=/api/custody/gaps p
  if [ -n "${1:-}" ]; then
    p=$(jq -rn --arg v "$1" '$v|@uri') || return 1
    path="$path?project=$p"
  fi
  _custody_call gaps "${1:-}" "" "" GET "$path"
}

# shellcheck shell=bash
# bin/lib/ticket-edges.sh — dependency edges and HOLD/RESUME comments as rows
# (BH-6977, BH-6547.1). The shell client of POST /api/ticket-edges and
# POST /api/ticket-holds (worker/jobs/src/routes/ticket-edges.js). Contract:
# docs/notes/2026-10-15-BH-6977-ticket-edges.md.
#
#   te_edges_from_text <file> [child]   pure: one "<parent>\t<hard|soft>" line
#                                       per distinct blocker the text declares
#   te_put_edges <project> <child> <source> <text-file> [planned-files-file]
#   te_put_verdict <project> <child> <parent> <HARD|SOFT>
#   te_holds_from_comments              pure: REST comments JSON on stdin, one
#                                       "<hold|resume>\t<login>\t<created_at>\t<comment id>"
#                                       line per person HOLD or RESUME comment
#   te_put_holds <project> <ticket> <comments-json-file>
#
# THE te_put_* FUNCTIONS ARE FAIL-OPEN. They print nothing on stdout and
# return 0 whatever happens, so a caller's own output and exit code never move.
# A failed request (no answer, 4xx, 5xx) writes one line to
# logs/ticket-edges.log and is not retried (JOBS_RETRIES=0); the next plan,
# verdict or comment wake writes the row again. Nothing reads these rows for a
# dispatch decision yet.
#
# Kill switch: lane_switch ticket-edges-off (settings row
# switch.ticket-edges-off, else flags/ticket-edges-off) makes every te_put_*
# return at once with no request. A ticket id that is not an issue number (an in-app board key)
# sends nothing. The root is ${HARNESS:-${H:-}}; with no root nothing is sent.
#
# Sourced, never executed. Nothing runs on source. bin/jobs-client.sh,
# bin/lib/dep-verify-lib.sh and bin/lib/hold.sh are sourced on first use when
# their functions are not already defined.

_te_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _te_ready — rc 0 when a te_put_* may send: a root, no kill flag, a client.
_te_ready() {
  local r; r=$(_te_root)
  [ -n "$r" ] || return 1
  if ! declare -F ls_isolated >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" >/dev/null 2>&1 || true
  fi
  if declare -F ls_isolated >/dev/null 2>&1 \
     && JOBS_ALERT=0 HARNESS="$r" ls_isolated lane_switch ticket-edges-off file >/dev/null 2>&1; then
    return 1
  fi
  if ! declare -F _jobs_req >/dev/null 2>&1; then
    # bin/jobs-client.sh exits when a module is missing. A probe in a subshell
    # first, so that exit can never end the caller (dep-verify's one line).
    # shellcheck source=bin/jobs-client.sh
    ( . "$(dirname "${BASH_SOURCE[0]}")/../jobs-client.sh" ) >/dev/null 2>&1 \
      && . "$(dirname "${BASH_SOURCE[0]}")/../jobs-client.sh" >/dev/null 2>&1
  fi
  declare -F _jobs_req >/dev/null 2>&1 || { _te_log ticket-edges "no jobs client (bin/jobs-client.sh)"; return 1; }
  return 0
}

_te_log() { # _te_log <log-name> <line>
  local r; r=$(_te_root)
  [ -n "$r" ] || return 0
  { mkdir -p "$r/logs" && printf '%s %s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" "$2" >> "$r/logs/$1.log"; } 2>/dev/null
  return 0
}

# _te_post <path> <json> <what> — one POST, no retry, no ALERTS line. A non-2xx
# answer or no answer is one log line naming the HTTP status.
_te_post() {
  local rc
  JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 _jobs_req POST "$1" "$2" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && return 0
  _te_log ticket-edges "POST $3 http=${JOBS_HTTP:-none}"
  return 0
}

_te_num() { [[ ${1:-} =~ ^[1-9][0-9]{0,8}$ ]]; }

te_edges_from_text() {
  local f="${1:-}" child="${2:-}" n kind
  [ -r "$f" ] || return 0
  if ! declare -F dep_depends_line >/dev/null 2>&1; then
    # shellcheck source=bin/lib/dep-verify-lib.sh
    . "$(dirname "${BASH_SOURCE[0]}")/dep-verify-lib.sh" >/dev/null 2>&1 || true
  fi
  # The line shapes bin/lib/stall-alerts.sh:stall_hard_blockers and
  # bin/lib/dep-verify-lib.sh (dep_declared_hard, dep_depends_line) read.
  for n in $( {
      grep -iE '^[[:space:]>*_#-]*blocked[- ]by\b' "$f" | grep -oE '#[0-9]+' | tr -d '#'
      sed -nE 's/^[[:space:]>*_#-]*needs\b[^#]*#([0-9]+).*/\1/Ip' "$f"
      sed -nE 's/^[[:space:]>*_-]*(\*\*)?DEPENDS[[:space:]]*:[[:space:]]*#([0-9]+).*/\2/Ip' "$f"
    } 2>/dev/null | sort -nu); do
    _te_num "$n" || continue
    [ "$n" = "$child" ] && continue
    # A DEPENDS line decides the kind. Every other blocker line is hard: the
    # reading that can never release a build early.
    kind=hard
    if declare -F dep_depends_line >/dev/null 2>&1; then
      case "$(dep_depends_line "$n" "$f" 2>/dev/null)" in soft\ *) kind=soft ;; esac
    fi
    printf '%s\t%s\n' "$n" "$kind"
  done
  return 0
}

te_put_edges() {
  local project="${1:-}" child="${2:-}" source="${3:-}" f="${4:-}" pf="${5:-}" files=null parent kind body
  _te_num "$child" && [ -n "$project" ] && [ -n "$source" ] && [ -r "$f" ] || return 0
  _te_ready || return 0
  # The planned paths, blank and `SOURCE:` lines dropped, capped at the
  # route's bounds (500 paths of at most 300 chars).
  if [ -n "$pf" ] && [ -r "$pf" ]; then
    files=$(jq -Rsc 'split("\n") | map(sub("^\\s+|\\s+$"; "")) | map(select(length > 0 and length <= 300 and (startswith("SOURCE:") | not))) | .[0:500]' "$pf" 2>/dev/null) || files=null
    [ -n "$files" ] || files=null
  fi
  while IFS=$'\t' read -r parent kind; do
    [ -n "$parent" ] || continue
    body=$(jq -nc --arg p "$project" --arg a "$parent" --arg c "$child" --arg k "$kind" --arg s "$source" --argjson f "$files" \
      '{project:$p,parent:$a,child:$c,kind:$k,source:$s} + (if $f == null then {} else {planned_files:$f} end)' 2>/dev/null) || continue
    _te_post /api/ticket-edges "$body" "$parent->$child"
  done < <(te_edges_from_text "$f" "$child")
  return 0
}

te_put_verdict() {
  local project="${1:-}" child="${2:-}" parent="${3:-}" kind body
  case "${4:-}" in HARD) kind=hard ;; SOFT) kind=soft ;; *) return 0 ;; esac
  _te_num "$child" && _te_num "$parent" && [ "$child" != "$parent" ] && [ -n "$project" ] || return 0
  _te_ready || return 0
  body=$(jq -nc --arg p "$project" --arg a "$parent" --arg c "$child" --arg k "$kind" \
    '{project:$p,parent:$a,child:$c,kind:$k,source:"dep-verify"}' 2>/dev/null) || return 0
  _te_post /api/ticket-edges "$body" "$parent->$child"
  return 0
}

# What a HOLD and a lift are is bin/lib/hold.sh's `decide` over people(): one
# spelling in the repo. Only person comments with a numeric id, a login and an
# ISO created_at make a line; needs-human, abandon, done and none make none.
te_holds_from_comments() {
  if [ -z "${HOLD__JQ_DEFS:-}" ]; then
    # shellcheck source=bin/lib/hold.sh
    . "$(dirname "${BASH_SOURCE[0]}")/hold.sh" >/dev/null 2>&1 || true
  fi
  [ -n "${HOLD__JQ_DEFS:-}" ] || return 0
  jq -rn \
    --arg hold "$HOLD_COMMENT_RE" --arg lift "$HOLD_LIFT_RE" --arg neg "$HOLD_NEG_RE" \
    --arg ab "$HOLD_ABANDON_RE" --arg lead "$HOLD_LIFT_LEAD_RE" --arg holdlead "$HOLD_LEAD_RE" --arg mark "$HOLD_AMBIGUOUS_MARK" \
    --arg nh "$HOLD_NEEDS_HUMAN_RE" --arg hf "$HOLD_HUMAN_FIX_RE" --arg done "$HOLD_HUMAN_DONE_RE" \
    --arg gl "${HOLD_GOLIVE_RE:-}" "$HOLD__JQ_DEFS"'
    input as $c
    | if ($c | type) != "array" then empty else
        people($c)[]
        | (.body | decide) as $d
        | select($d == "hold" or $d == "lift")
        | ((($c[.i].user // {}).login // "") | tostring) as $login
        | select((.id | type) == "number" and $login != "" and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")))
        | [(if $d == "hold" then "hold" else "resume" end), $login, .at, (.id | tostring)] | @tsv
      end' 2>/dev/null
  return 0
}

te_put_holds() {
  local project="${1:-}" ticket="${2:-}" cf="${3:-}" state by at cid body
  _te_num "$ticket" && [ -n "$project" ] && [ -r "$cf" ] || return 0
  _te_ready || return 0
  while IFS=$'\t' read -r state by at cid; do
    [ -n "$cid" ] || continue
    body=$(jq -nc --arg p "$project" --arg t "$ticket" --arg s "$state" --arg b "$by" --arg a "$at" --arg i "$cid" \
      '{project:$p,ticket:$t,state:$s,by:$b,at:$a,comment_id:$i}' 2>/dev/null) || continue
    _te_post /api/ticket-holds "$body" "hold #$ticket comment $cid"
  done < <(te_holds_from_comments < "$cf")
  return 0
}

#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/alerts.sh — BH-1068 (split child of BH-1030): the alerts table — the fleet's incident rows: note/state/resolve, the lane claim and the flush claim, and the list and family readouts. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# ── Alerts table contract (BH-1068) ──────────────────────────────────────────
# Thin wrappers over the worker's alert endpoints. Every call goes through
# _jobs_req and returns its rc verbatim: 0 body, 2 no row, 9 conflict, 1 outage.
# Siblings that actually move alerts import these and test alerts_db_on first.

# Shared TSV renderer: id family box project state count first_seen last_seen
# claimed_by notified_at severity line, with line LAST so an embedded tab cannot
# shift the columns a reader parses.
_alerts_list_resp() {
  local method="$1" path="$2" body="${3:-}" resp rc
  local rows
  resp=$(_jobs_req "$method" "$path" "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # A 200 THAT IS NOT JSON IS AN OUTAGE. Swallowing jq's rc made a Cloudflare
  # error page, an HTML-serving worker and a truncated body indistinguishable
  # from an empty table — rc 0, no rows — to every caller, including a flush
  # lane deciding there is nothing to escalate.
  rows=$(printf '%s' "$resp" | jq -r '.alerts[]? | [
    .id, .family, .box, .project, .state, (.count // 1),
    .first_seen, .last_seen, (.claimed_by // ""), (.claimed_at // ""), (.notified_at // ""),
    .severity, .line ] | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] && printf '%s\n' "$rows"
  [ "$(printf '%s' "$resp" | jq -r '.truncated // false' 2>/dev/null)" = "true" ] && printf '#truncated\n'
  return 0
}

# alert_note <id> <family> <box> <project> <severity> <line> [reminder_s] [close_s] [state]
#   Prints "<decision> <count>" (the same shape alert_state_note prints today).
alert_note() {
  local id="${1:-}" family="${2:-}" box="${3:-$JOBS_BOX}" project="${4:-}"         severity="${5:-}" line="${6:-}" reminder_s="${7:-}" close_s="${8:-}" state="${9:-new}" body resp rc
  [ -n "$id" ] && [ -n "$severity" ] && [ -n "$line" ] || return 1
  body=$(jq -nc --arg id "$id" --arg family "$family" --arg box "$box"     --arg project "$project" --arg severity "$severity" --arg line "$line"     --arg reminder_s "$reminder_s" --arg close_s "$close_s" --arg state "$state"     '{id:$id}
     + (if $family == "" then {} else {family:$family} end)
     + {box:$box, project:$project, severity:$severity, line:$line}
     + (if $state == "" then {} else {state:$state} end)
     + (if ($reminder_s|test("^[0-9]+$")) then {reminder_s:($reminder_s|tonumber)} else {} end)
     + (if ($close_s|test("^[0-9]+$")) then {close_s:($close_s|tonumber)} else {} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/alerts/note "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # A 200 that does not parse is an outage (rc 1), not a blank line and rc 0.
  local out
  out=$(printf '%s' "$resp" | jq -r '[.decision, (.count // 1)] | @tsv' 2>/dev/null) || return 1
  printf '%s\n' "$(printf '%s' "$out" | tr '\t' ' ')"
}

# alert_state_set <id> <state> [actor] — prints 1 when the row came back in the
# state we asked for, 0 otherwise (a 404/409 is an rc, never a printed 0).
alert_state_set() {
  local id="${1:-}" state="${2:-}" actor="${3:-}" body resp rc
  [ -n "$id" ] && [ -n "$state" ] || return 1
  body=$(jq -nc --arg id "$id" --arg state "$state" --arg actor "$actor"     '{id:$id, state:$state} + (if $actor == "" then {} else {actor:$actor} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req PATCH /api/alerts/state "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  local out
  out=$(printf '%s' "$resp" | jq -r --arg s "$state" \
    'if (.alert.state // "") == $s then 1 else 0 end' 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# alert_resolve <id>... — variadic ids, one request; prints the worker's
# `resolved` count (rows that MOVED). 0 is a real answer, never an error.
alert_resolve() {
  [ "$#" -gt 0 ] || return 1
  local ids body resp rc
  ids=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != ""))' 2>/dev/null) || return 1
  body=$(jq -nc --argjson ids "$ids" '{ids:$ids}' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/alerts/resolve "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  local out
  out=$(printf '%s' "$resp" | jq -r '.resolved // 0' 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# alert_resolve_rows <id>... — alert_resolve, plus the rows that moved (BH-7802).
#   Prints one "<id>\t<count>\t<severity>\t<first_seen>" line per moved row,
#   then "resolved <n>". A worker that answers no `rows` key (one deployed
#   before BH-7802) prints "#norows" in their place. rc 1 for a 200 that is not
#   JSON or has no numeric `resolved`: an answer we cannot read is not a 0.
alert_resolve_rows() {
  [ "$#" -gt 0 ] || return 1
  local ids body resp rc out
  ids=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != ""))' 2>/dev/null) || return 1
  body=$(jq -nc --argjson ids "$ids" '{ids:$ids}' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/alerts/resolve "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  out=$(printf '%s' "$resp" | jq -r '
    if (.resolved | type) != "number" then error("no resolved count") else . end
    | (if has("rows") then (.rows[] | [.id, (.count // 1), (.severity // ""), (.first_seen // "")] | @tsv)
       else "#norows" end),
      "resolved \(.resolved)"' 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# alert_row <id> — the one row of <id> as the 13-column TSV _alerts_list_resp
#   prints, or nothing (rc 0) when the worker has no such row (BH-7802). rc as
#   _jobs_req, and rc 1 for an id the worker would refuse, or for an answer
#   whose row is another id: a worker that does not know ?id= answers its
#   newest row, and that is not this condition.
alert_row() {
  local id="${1:-}" out rc row
  case "$id" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  out=$(_alerts_list_resp GET "/api/alerts?id=$id&limit=1"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  row=$(printf '%s\n' "$out" | grep -v '^#' | head -n 1)
  [ -n "$row" ] || return 0
  [ "$(printf '%s' "$row" | cut -f1)" = "$id" ] || return 1
  printf '%s\n' "$row"
}

# alert_claim <lane> <state> [min_age_s] [limit] [id...]
alert_claim() {
  local lane="${1:-}" state="${2:-}" min_age_s="${3:-}" limit="${4:-}" body ids
  [ -n "$lane" ] && [ -n "$state" ] || return 1
  # SHIFT PAST THE OPTIONS TOO. min_age_s and limit are read from $3/$4 but were
  # left in "$@", so `alert_claim medic new 60 10` sent ids:["60","10"] — ids the
  # worker accepts, matches nothing on, and answers 200 {alerts:[]} for. The
  # documented call claimed nothing, forever, with no error anywhere.
  shift $(( $# < 4 ? $# : 4 ))
  if [ "$#" -gt 0 ]; then
    ids=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != ""))' 2>/dev/null) || return 1
  fi
  # CARRY THE BOX. claimed_by is `<lane>@<box>` and the worker composes it from
  # this field; a claim sent without one is filed under the bare lane, which
  # `alert_families <lane>` (substr(claimed_by,1,n)='<lane>@') can never match —
  # the 6h family brake would answer nothing every tick, silently. A lane that
  # already carries its own `@box` is sent as-is, or the claimant doubles.
  body=$(jq -nc --arg lane "$lane" --arg state "$state" --arg box "${JOBS_BOX:-}"     --arg min "$min_age_s" --arg lim "$limit" --argjson ids "${ids:-null}"     '{lane:$lane, state:$state}
     + (if $box == "" or ($lane|test("@")) then {} else {box:$box} end)
     + (if ($min|test("^[0-9]+$")) then {min_age_s:($min|tonumber)} else {} end)
     + (if ($lim|test("^[0-9]+$")) then {limit:($lim|tonumber)} else {} end)
     + (if $ids == null then {} elif ($ids|length) == 0 then {} else {ids:$ids} end)' 2>/dev/null) || return 1
  _alerts_list_resp POST /api/alerts/claim "$body"
}

# alert_flush_claim [box] — claim alerts whose lease has expired.
alert_flush_claim() {
  local box="${1:-$JOBS_BOX}" body
  body=$(jq -nc --arg box "$box" '{box:$box}' 2>/dev/null) || return 1
  _alerts_list_resp POST /api/alerts/flush "$body"
}

# alerts_list [--state s] [--family f] [--box b] [--older-than s] [--since s] [--limit n]
#             [--component c | --unstamped]   (BH-6971: rows of one component, or rows with none)
alerts_list() {
  local state="" family="" box="" older_than="" since="" limit="" component="" unstamped="" q="" resp
  while [ $# -gt 0 ]; do
    case "$1" in
      --state)      state="${2:-}"; shift 2 ;;
      --family)     family="${2:-}"; shift 2 ;;
      --box)        box="${2:-}"; shift 2 ;;
      --older-than) older_than="${2:-}"; shift 2 ;;
      --since)      since="${2:-}"; shift 2 ;;
      --limit)      limit="${2:-}"; shift 2 ;;
      --component)  component="${2:-}"; shift 2 ;;
      --unstamped)  unstamped=1; shift ;;
      *) return 1 ;;
    esac
  done
  [ -n "$state" ]      && q="${q:+$q&}state=$state"
  [ -n "$family" ]     && q="${q:+$q&}family=$family"
  [ -n "$box" ]        && q="${q:+$q&}box=$box"
  [ -n "$older_than" ] && q="${q:+$q&}older_than=$older_than"
  [ -n "$since" ]      && q="${q:+$q&}since=$since"
  [ -n "$limit" ]      && q="${q:+$q&}limit=$limit"
  [ -n "$component" ]  && q="${q:+$q&}component=$component"
  [ -n "$unstamped" ]  && q="${q:+$q&}unstamped=1"
  _alerts_list_resp GET "/api/alerts${q:+?$q}"
}

# alert_components_stamp — BH-6971: stdin `<id>\t<component>` lines (the
# output of bin/component-of.sh --batch), POST /api/alerts/component in chunks
# of at most 200 (the route refuses more). Prints the sum of the worker's
# `stamped` counts: rows that CHANGED, never the number sent. No input line is
# rc 0 and prints 0 with no request. A failed chunk stops the loop: the rc
# passes through verbatim (a 200 that is not {stamped:<n>} is rc 1) and the
# count printed is what the chunks BEFORE it stamped, so a caller never logs
# rows as unstamped that a first chunk already changed.
alert_components_stamp() {
  local all chunk body resp rc n total=0 i=0 len
  all=$(jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {id: .[0], component: .[1]})' 2>/dev/null) || return 1
  len=$(jq -r 'length' <<<"$all" 2>/dev/null) || return 1
  while [ "$i" -lt "$len" ]; do
    chunk=$(jq -c --argjson i "$i" '.[$i:$i+200]' <<<"$all" 2>/dev/null) || return 1
    body=$(jq -nc --argjson s "$chunk" '{stamps:$s}' 2>/dev/null) || return 1
    resp=$(_jobs_req POST /api/alerts/component "$body"); rc=$?
    [ "$rc" -eq 0 ] || { printf '%s\n' "$total"; return "$rc"; }
    n=$(printf '%s' "$resp" | jq -er '.stamped | select(type == "number")' 2>/dev/null) \
      || { printf '%s\n' "$total"; return 1; }
    total=$((total + n)); i=$((i + 200))
  done
  printf '%s\n' "$total"
}

# alert_families <lane> <claimed_since_s> [state] — TSV: family last_claimed_at n.
alert_families() {
  local lane="${1:-}" claimed_since_s="${2:-}" state="${3:-}" q resp rc
  [ -n "$lane" ] || return 1
  q="lane=$lane"
  [ -n "$claimed_since_s" ] && q="$q&claimed_since_s=$claimed_since_s"
  [ -n "$state" ] && q="$q&state=$state"
  resp=$(_jobs_req GET "/api/alerts/families?$q"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  local rows
  rows=$(printf '%s' "$resp" | jq -r '.families[]? | [.family, .last_claimed_at, (.n // 0)] | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] && printf '%s\n' "$rows"
  return 0
}


# alert_family_scripts — the alert-family registry (BH-2544), read once per tick
# by bin/triage-family-scripts.sh. Prints `id match_kind match verify on_clear
# on_repro priority` as TSV for ENABLED rows, ordered priority,id here rather
# than trusted from the route (which returns disabled rows too). The rc passes
# through: a 404 (route not deployed) is 2, an outage 1, and a 200 that is not
# {rows:[...]} is 1 — never an empty list. Zero enabled rows is rc 0, no output.
alert_family_scripts() {
  local resp rc rows
  resp=$(_jobs_req GET /api/alert-family-scripts); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  rows=$(printf '%s' "$resp" | jq -r 'if (.rows | type) == "array" then .rows else error("no rows array") end
    | map(select((.enabled // 1) as $e | $e == 1 or $e == true))
    | sort_by([(.priority // 100), .id]) | .[]
    | [.id, .match_kind, .match, (.verify // ""), (.on_clear // "settle"), (.on_repro // "model"), (.priority // 100)] | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] && printf '%s\n' "$rows"
  return 0
}

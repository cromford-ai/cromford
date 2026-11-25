#!/bin/bash
# bin/lib/sentry-triage.sh — BH-5620 (BH-5611.4): the functions of the
# sentry-triage hub lane. Sourced by bin/sentry-triage.sh, never executed.
#
#   st_list_issues <out>         GET the unresolved issues of SENTRY_TRIAGE_PROJECT
#                                seen in the last SENTRY_TRIAGE_LOOKBACK_H hours.
#                                Prints the HTTP code. rc 0 only on 2xx + array.
#   st_issue <issue-json>        ONE issue, every rule below. Sets ST_OUT to
#                                below_min|terminal|called|filed|commented|noise|
#                                failed|capped|healed|skip and returns 0, or
#                                returns 75 when the tick must make no more calls,
#                                with ST_STOP=ledger (the jobs ledger, the day row
#                                included, is unreadable) or ST_STOP=open-list.
#
# DEDUP BEFORE SPEND. The ledger row sentry-triage/<key> is read FIRST. <key> is
# ST_KEY_PREFIX + the Sentry issue id, or + <id>:regressed for a regressed issue whose <id> row is
# terminal. One regression pass per issue in total: a later regression after a
# <id>:regressed row exists gets nothing (a deliberate limit). An issue that was
# already regressed when its <id> pass ran (detail.regressed true) has had its
# regression pass: it gets no <id>:regressed pass.
#   ticketed | noise | failed  terminal, no call;
#   diagnosed                  paid for: act on the stored diagnosis, no call
#                              (the evidence is fetched again; a diagnosis that
#                              cannot be read is failed {why: diagnosis-lost});
#   retry, attempts >= 3       written failed, no call;
#   retry < 3, or no row       the open-issue marker heal, the day ticket cap,
#                              the day call cap (counted BEFORE the call), then
#                              the attempt is written BEFORE the call.
# An unreadable ledger makes no call for the rest of the tick (fail closed).
# agent-call rc 74-79 billed nothing and restores the prior attempts; another
# non-zero keeps the attempt and is failed at 3. rc 0 with an empty or
# off-contract answer is failed at once (billed, never re-called). A valid
# answer is written `diagnosed` first, then acted on: noise is terminal, a
# comment goes on the named candidate ticket, a ticket is created in
# HARNESS_REPO (only a 201 with a number counts). A comment carries the body
# marker and is not posted again when the ticket's first comment page has it.
# A failed post or create leaves `diagnosed` for the next tick, with no new call. After `ticketed`, the ticket
# link is written back to the Sentry issue once; 401/403 is logged and skipped.
#
# Ledger detail (job_ledger_put replaces it, so every write merges the prior):
#   {sentry_id, short_id, permalink, regressed, attempts, last_rc, diagnosis,
#    action, issue, url, filed_at, reason, why, writeback, cut}
# The worker cuts detail at 4000 chars (worker/jobs/src/routes/ledger.js), and
# a cut detail is not JSON. _st_save cuts the diagnosis text fields first, so
# the stored detail stays under ST_DETAIL_MAX bytes (cut = the field limit used).
# Day row sentry-triage-day/<ST_KEY_PREFIX><YYYY-MM-DD>: {filed: [<sentry ids>], calls: <n>}.
# calls counts the model calls started that day; SENTRY_TRIAGE_MAX_CALLS_DAY caps it.
# Body marker: <!-- sentry-issue: <key> --> on a ticket and on a comment.
#
# SHARED WITH discovery-daily (BH-9795). bin/lib/discovery-daily.sh sources this
# file and sets these globals; each one defaults to the sentry-triage value, so
# sentry-triage sets nothing and behaves as before:
#   ST_LANE          log file, log tag and ledger kinds (<lane>, <lane>-day)
#   ST_MAX_ATTEMPTS  attempts before an item is failed (3)
#   ST_OPEN_LABEL    the label of the open-issue read (ai-build; empty = all)
#   ST_RAW_DIR       when set, st_latest_event keeps Sentry's raw answer there
# and these per-source globals (BH-9799), set by bin/sentry-triage.sh for each
# Sentry source and left unset by discovery-daily:
#   ST_KEY_PREFIX    put before every ledger key, day-row key and body marker
#                    key (`<project>:` for a registry source; empty = the keys
#                    as before: <id>, <id>:regressed, <YYYY-MM-DD>)
#   ST_TOKEN         the Sentry token of the source; empty = SENTRY_API_TOKEN
#   ST_SOURCE_LABEL  the `## Sentry source` prompt line after <org>/<slug>
# Every log line, ticket title, ticket body and comment body passes through
# token_redact (bin/lib/token-redact.sh). A body that cannot be scrubbed is not
# posted: the item stays `diagnosed`.
# and these helpers carry the ledger, filing and call rules for both lanes:
# _st_attempt_put, _st_after_call, _st_create, _st_comment_once, _st_day_filed_add.
#
# gh-rest: no-graphql
[ "$(type -t gh_rest)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" 2>/dev/null
[ "$(type -t gh_rest_issue_list)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh" 2>/dev/null
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/deployment.sh}" || return 1
# shellcheck source=bin/lib/token-redact.sh
[ "$(type -t token_redact)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/token-redact.sh" || return 1

ST_API="https://sentry.io/api/0"
# Bytes. A UTF-8 byte count is never below the worker's UTF-16 slice count.
ST_DETAIL_MAX=3900

_st_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_st_log() { local r l="${ST_LANE:-sentry-triage}"; r=$(_st_root); [ -n "$r" ] || return 0; printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$l" "$*" | token_redact >> "$r/logs/$l.log"; }
_st_dash() { sed 's/[—–]/-/g'; }

# _st_knob_int <name> <value> <default> <min> <max>: out of range is one log line
# and the default, never a clamp (D11).
_st_knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    _st_log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}

# st_knobs: read every knob once per tick.
st_knobs() {
  ST_MIN_EVENTS=$(_st_knob_int SENTRY_TRIAGE_MIN_EVENTS "${SENTRY_TRIAGE_MIN_EVENTS:-3}" 3 1 100000)
  ST_MAX_DAY=$(_st_knob_int SENTRY_TRIAGE_MAX_TICKETS_DAY "${SENTRY_TRIAGE_MAX_TICKETS_DAY:-5}" 5 0 50)
  ST_MAX_CALLS_DAY=$(_st_knob_int SENTRY_TRIAGE_MAX_CALLS_DAY "${SENTRY_TRIAGE_MAX_CALLS_DAY:-10}" 10 0 200)
  ST_LOOKBACK_H=$(_st_knob_int SENTRY_TRIAGE_LOOKBACK_H "${SENTRY_TRIAGE_LOOKBACK_H:-24}" 24 1 336)
  ST_HOTFIX_24H=$(_st_knob_int SENTRY_TRIAGE_HOTFIX_EVENTS_24H "${SENTRY_TRIAGE_HOTFIX_EVENTS_24H:-50}" 50 1 1000000)
  ST_LOG_LINES=$(_st_knob_int SENTRY_TRIAGE_LOG_LINES "${SENTRY_TRIAGE_LOG_LINES:-40}" 40 0 200)
  ST_LOG_WINDOW_MIN=$(_st_knob_int SENTRY_TRIAGE_LOG_WINDOW_MIN "${SENTRY_TRIAGE_LOG_WINDOW_MIN:-10}" 10 1 120)
  ST_MAX_USD="${SENTRY_TRIAGE_MAX_USD:-0.50}"
  if ! [[ $ST_MAX_USD =~ ^[0-9]+(\.[0-9]+)?$ ]] || awk -v v="$ST_MAX_USD" 'BEGIN{exit !(v > 5)}'; then
    _st_log "warn: SENTRY_TRIAGE_MAX_USD=$ST_MAX_USD is outside 0..5; using the default 0.50"
    ST_MAX_USD=0.50
  fi
  ST_PROJECT="${SENTRY_TRIAGE_PROJECT:-cromford-harness}"
  ST_ORG="${SENTRY_ORG:-operator}"
  ST_REPO="${HARNESS_REPO:-}"
}

# _st_curl <out> <url> [curl args...]: prints the HTTP code ("000" on a transport
# failure). The token rides as a header and is never printed.
_st_curl() {
  local out=$1 url=$2 code; shift 2
  code=$(curl -sS -m 25 -o "$out" -w '%{http_code}' -H "Authorization: Bearer ${ST_TOKEN:-${SENTRY_API_TOKEN:-}}" "$@" "$url" 2>/dev/null) || code=000
  [[ $code =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "$code"
}

st_list_issues() { # st_list_issues <out>
  local out=$1 q code
  q=$(jq -nr --arg q "is:unresolved lastSeen:-${ST_LOOKBACK_H}h" '$q | @uri')
  code=$(_st_curl "$out" "$ST_API/projects/$ST_ORG/$ST_PROJECT/issues/?query=$q&statsPeriod=24h&limit=100")
  printf '%s' "$code"
  [[ $code == 2?? ]] && jq -e 'type == "array"' "$out" >/dev/null 2>&1
}

# st_latest_event <id> <out>: the latest event cut to what the model needs, as
# valid JSON (message 4000 chars, each exception value 1000, the last 30 frames),
# so the tags stay readable. The prompt cuts it again to 12000 bytes. rc 1 when
# Sentry did not answer 2xx with an object.
st_latest_event() {
  local id=$1 out=$2 raw code
  raw=$(mktemp "${TMPDIR:-/tmp}/st-event.XXXXXX") || return 1
  code=$(_st_curl "$raw" "$ST_API/issues/$id/events/latest/")
  [ -n "${ST_RAW_DIR:-}" ] && cp "$raw" "$ST_RAW_DIR/event-$id.json" 2>/dev/null
  if [[ $code != 2?? ]] || ! jq -e 'type == "object"' "$raw" >/dev/null 2>&1; then
    printf 'latest event unavailable (HTTP %s)\n' "$code" > "$out"; rm -f "$raw"; return 1
  fi
  jq -c '{title: ((.title // "") | .[0:500]), message: ((.message // "") | .[0:4000]), dateCreated,
       tags: ((.tags // []) | map(select(.key | IN("lane", "project", "box", "harness_sha", "reason")) | {(.key): .value}) | add // {}),
       exception: [(.entries // [])[] | select(.type == "exception") | .data.values[]?
         | {type, value: ((.value // "") | .[0:1000]), frames: ((.stacktrace.frames // [])[-30:] | map({filename, function, lineNo}))}]}' \
    "$raw" > "$out" 2>/dev/null
  rm -f "$raw"
  return 0
}

# st_log_lines <lane> <box> <reason> <dateCreated>: the lane's log lines near
# the event, only when the event came from this box. Never a path from a tag.
st_log_lines() {
  local lane=$1 box=$2 reason=$3 at=$4 me f ep lo hi out=""
  me="${JOBS_BOX:-$(hostname -s 2>/dev/null)}"
  if [ "$ST_LOG_LINES" = 0 ]; then echo "log lines off (SENTRY_TRIAGE_LOG_LINES=0)"; return 0; fi
  f="$(_st_root)/logs/$lane.log"
  if ! [[ $lane =~ ^[a-z0-9-]+$ ]]; then echo "the event names no usable lane tag; no log read"; return 0; fi
  if [ -z "$box" ] || [ "$box" != "$me" ]; then
    echo "log for lane $lane is on box ${box:-<none>}; not read from the hub"; return 0
  fi
  if [ ! -r "$f" ]; then echo "no log file for lane $lane on this box"; return 0; fi
  if [ -n "$at" ] && ep=$(date -u -d "$at" +%s 2>/dev/null); then
    lo=$(date -u -d "@$((ep - ST_LOG_WINDOW_MIN * 60))" '+%F %T')
    hi=$(date -u -d "@$((ep + ST_LOG_WINDOW_MIN * 60))" '+%F %T')
    out=$(awk -v lo="$lo" -v hi="$hi" '
      match($0, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
        s = substr($0, 1, 19); sub(/T/, " ", s); if (s >= lo && s <= hi) print }' "$f" | tail -n "$ST_LOG_LINES")
  fi
  if [ -z "$out" ] && [ -n "$reason" ]; then out=$(grep -F -- "$reason" "$f" | tail -n "$ST_LOG_LINES"); fi
  if [ -z "$out" ]; then echo "no line of $lane.log is near the event or names its reason"; else printf '%s\n' "$out"; fi
}

# st_open_list: the ONE open-issue read of the tick (label ST_OPEN_LABEL,
# default ai-build; empty reads every open issue), cached in ST_OPEN.
# rc 1 when the read failed or hit the 1000-row cap (nothing absent is proven).
st_open_list() {
  [ -n "${ST_OPEN:-}" ] && [ -s "$ST_OPEN" ] && return 0
  local rc=0 len
  ST_OPEN="$ST_TMP/open.json"
  gh_rest_issue_list "$ST_REPO" open "${ST_OPEN_LABEL-ai-build}" 1000 > "$ST_OPEN" 2>/dev/null || rc=$?
  len=$(jq 'length' "$ST_OPEN" 2>/dev/null) || len=""
  if [ "$rc" != 0 ] || ! [[ $len =~ ^[0-9]+$ ]] || [ "$len" -ge 1000 ]; then
    rm -f "$ST_OPEN"; ST_OPEN=""
    _st_log "open issue list unverifiable (HTTP ${GH_REST_STATUS:-000}, rows ${len:-?}); no calls this tick"
    return 1
  fi
}

# st_candidates <reason>: up to 5 open issues whose title or body holds the
# reason tag (fixed string, case-sensitive), as a JSON array.
st_candidates() {
  if [ -z "$1" ]; then echo '[]'; return 0; fi
  jq -c --arg r "$1" '[.[] | select(((.title // "") | contains($r)) or ((.body // "") | contains($r)))
    | {number, title: (.title // ""), body: ((.body // "")[0:600])}] | sort_by(-.number) | .[0:5]' "$ST_OPEN"
}

# _st_detail <row-json>: the row's detail as an object ({} when absent).
_st_detail() {
  jq -c '.detail | if type == "string" then (fromjson? // {}) else . end | if type == "object" then . else {} end' <<<"$1" 2>/dev/null || echo '{}'
}
# _st_fit <detail-json>: the detail with each diagnosis text field cut to the
# largest limit that keeps it under ST_DETAIL_MAX bytes. Unchanged when it fits.
_st_fit() {
  local d=$1 lim f
  [ "$(printf '%s' "$d" | wc -c)" -le "$ST_DETAIL_MAX" ] && { printf '%s' "$d"; return 0; }
  for lim in 1500 800 400 150 40; do
    f=$(jq -c --argjson n "$lim" 'if (.diagnosis | type) == "object" then
        .diagnosis |= with_entries(.value |= (if type == "string" then .[0:$n]
          elif type == "array" then (.[0:10] | map(if type == "string" then .[0:($n / 4 | floor)] else . end)) else . end))
        | .cut = $n else . end' <<<"$d") || break
    [ "$(printf '%s' "$f" | wc -c)" -le "$ST_DETAIL_MAX" ] && { printf '%s' "$f"; return 0; }
  done
  printf '%s' "${f:-$d}"
}
# _st_save <key> <status> <detail-json>: every sentry-triage row write.
_st_save() {
  local d
  d=$(_st_fit "$3")
  [ "$d" = "$3" ] || _st_log "$1 detail over $ST_DETAIL_MAX bytes; the diagnosis text was cut to $(jq -r '.cut' <<<"$d") chars"
  job_ledger_put "${ST_LANE:-sentry-triage}" "$1" "$2" "$d"
}
# _st_put <key> <status> <prior-detail> <patch-json>: the prior detail carried forward.
_st_put() {
  local d
  d=$(jq -c --argjson p "$4" '. + $p' <<<"$3") || return 1
  _st_save "$1" "$2" "$d"
}

# _st_day: today's day row detail as {filed: [ids], calls: n}. rc 1 = unreadable.
_st_day() {
  local row rc=0
  row=$(job_ledger_row "${ST_LANE:-sentry-triage}-day" "${ST_KEY_PREFIX:-}$ST_DAY") || rc=$?
  case "$rc" in
    0) jq -c '.detail | if type == "string" then (fromjson? // {}) else . end | if type == "object" then . else {} end
         | {filed: (.filed // [] | if type == "array" then . else [] end), calls: (.calls // 0 | numbers? // 0 | floor)}' <<<"$row" 2>/dev/null \
         || echo '{"filed":[],"calls":0}' ;;
    2) echo '{"filed":[],"calls":0}' ;;
    *) return 1 ;;
  esac
}
# _st_day_filed: the Sentry ids filed today, as a JSON array. rc 1 = unreadable.
_st_day_filed() {
  local d
  d=$(_st_day) || return 1
  jq -c '.filed' <<<"$d"
}
# _st_day_call: count one model call in the day row BEFORE the call. rc 0 = the
# call may run; 1 = SENTRY_TRIAGE_MAX_CALLS_DAY reached; 2 = the day row is
# unreadable or the count could not be written (no call, fail closed).
_st_day_call() {
  local d n
  d=$(_st_day) || { _st_log "day row unreadable; no calls this tick"; return 2; }
  n=$(jq -r '.calls' <<<"$d")
  [ "$n" -ge "$ST_MAX_CALLS_DAY" ] && return 1
  job_ledger_put "${ST_LANE:-sentry-triage}-day" "${ST_KEY_PREFIX:-}$ST_DAY" counted "$(jq -c '.calls += 1' <<<"$d")" \
    || { _st_log "ledger put ${ST_LANE:-sentry-triage}-day/${ST_KEY_PREFIX:-}$ST_DAY calls failed; no call"; return 2; }
}
# _st_day_filed_add <id>: add one id to today's filed list. rc 1 = the day row
# is unreadable or the write failed (the write failure is logged).
_st_day_filed_add() {
  local day
  day=$(_st_day) || return 1
  job_ledger_put "${ST_LANE:-sentry-triage}-day" "${ST_KEY_PREFIX:-}$ST_DAY" counted "$(jq -c --arg i "$1" '.filed += [$i]' <<<"$day")" \
    || { _st_log "ledger put ${ST_LANE:-sentry-triage}-day/${ST_KEY_PREFIX:-}$ST_DAY failed"; return 1; }
}
# _st_day_capped: rc 0 when no new ticket may be filed today, 1 when one may,
# 2 when the day row is unreadable.
_st_day_capped() {
  local filed n
  filed=$(_st_day_filed) || { _st_log "day cap unverifiable; no calls this tick"; return 2; }
  n=$(jq 'length' <<<"$filed")
  [ "$n" -ge "$ST_MAX_DAY" ]
}

# _st_reply <raw-file>: the answer as compact JSON on stdout, or rc 1 (empty)
# or rc 2 (off the contract). The candidate numbers are in $cands.
_st_reply() {
  local raw=$1 j
  [ -n "$(tr -d '[:space:]' < "$raw")" ] || return 1
  # A fenced answer is accepted: the fence lines are dropped before the parse.
  j=$(sed '/^[[:space:]]*```/d' "$raw" | jq -c . 2>/dev/null) || return 2
  jq -e --argjson c "$cands" '
    type == "object" and (
      (.verdict == "ticket" and ((.title // "") | type == "string" and length > 0) and ((.cause // "") | type == "string" and length > 0))
      or (.verdict == "comment" and (.issue | type == "number") and (.issue as $n | $c | map(.number) | index($n) != null)
          and ((.comment // "") | type == "string" and length > 0))
      or (.verdict == "noise" and ((.reason // "") | type == "string" and length > 0)))' <<<"$j" >/dev/null 2>&1 || return 2
  printf '%s\n' "$j"
}

# _st_attempt_put <key> <detail> <n>: the attempt n+1 written as `retry` BEFORE
# the call. Prints the new detail. rc 1 = the write failed (no call).
_st_attempt_put() {
  _st_put "$1" retry "$2" "$(jq -nc --argjson a "$(($3 + 1))" '{attempts: $a}')" || return 1
  jq -c --argjson a "$(($3 + 1))" '. + {attempts: $a}' <<<"$2"
}

# _st_after_call <key> <prior-detail> <detail> <n> <rc>: the outcome of a
# non-zero agent-call rc. rc 74-79 billed nothing and restores the prior
# attempts; another rc keeps the attempt and is failed at ST_MAX_ATTEMPTS.
# Sets ST_OUT. rc 0 = handled; rc 1 = the call answered rc 0, go on.
_st_after_call() {
  local key=$1 prior=$2 det=$3 n=$4 arc=$5 max="${ST_MAX_ATTEMPTS:-3}"
  [ "$arc" != 0 ] || return 1
  if [ "$arc" -ge 74 ] && [ "$arc" -le 79 ]; then
    _st_put "$key" retry "$prior" "$(jq -nc --argjson a "$n" --argjson r "$arc" '{attempts: $a, last_rc: $r}')" \
      || _st_log "ledger put restore for $key failed"
    _st_log "$key agent-call refused (rc $arc), nothing billed; attempts stay $n"; ST_OUT=skip; return 0
  fi
  if [ "$((n + 1))" -ge "$max" ]; then
    _st_put "$key" failed "$det" "$(jq -nc --argjson r "$arc" '{last_rc: $r, why: "attempts"}')" || _st_log "ledger put failed for $key failed"
    _st_log "$key agent-call rc $arc; failed after $((n + 1)) attempts"; ST_OUT=failed; return 0
  fi
  _st_put "$key" retry "$det" "$(jq -nc --argjson r "$arc" '{last_rc: $r}')" || _st_log "ledger put retry for $key failed"
  _st_log "$key agent-call rc $arc; attempt $((n + 1)) of $max"; ST_OUT=skip; return 0
}

# _st_create <title> <body-file> <labels-json>: POST repos/$ST_REPO/issues.
# Only a 201 with a number counts. Sets ST_NUM and ST_URL. rc 1 = not created.
_st_create() {
  local pf="$ST_TMP/payload.json" rc=0 t
  ST_NUM=""; ST_URL=""
  t=$(printf '%s\n' "$1" | token_redact) || return 1
  token_redact_file "$2" || { _st_log "token scrub of the ticket body failed; not posted"; return 1; }
  jq -n --arg t "$t" --rawfile b "$2" --argjson l "$3" '{title: $t, body: $b, labels: $l}' > "$pf" || return 1
  gh_rest POST "repos/$ST_REPO/issues" --input "$pf" > "$ST_TMP/created" || rc=$?
  ST_NUM=$(jq -e '.number | numbers' "$ST_TMP/created" 2>/dev/null) || ST_NUM=""
  if [ "$rc" != 0 ] || [ "${GH_REST_STATUS:-}" != 201 ] || [ -z "$ST_NUM" ]; then ST_NUM=""; return 1; fi
  ST_URL=$(jq -r '.html_url // ""' "$ST_TMP/created")
}

# _st_comment_once <key> <n> <body-file> <marker>: post the comment on #n
# unless the first comment page (100) already holds the marker. rc 0 = posted
# or already there; rc 1 = the page is unreadable or the post failed (logged).
_st_comment_once() {
  local key=$1 n=$2 bf=$3 m=$4 rc=0
  gh_rest GET "repos/$ST_REPO/issues/$n/comments" -F per_page=100 > "$ST_TMP/comments.json" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$ST_TMP/comments.json" >/dev/null 2>&1; then
    _st_log "$key comments of #$n unreadable (HTTP ${GH_REST_STATUS:-000}); stays diagnosed"; return 1
  fi
  if jq -e --arg m "$m" 'any(.[]; (.body // "") | contains($m))' "$ST_TMP/comments.json" >/dev/null 2>&1; then
    _st_log "$key comment already on #$n (marker); not posted again"
  elif ! token_redact_file "$bf"; then
    _st_log "$key token scrub of the comment failed; not posted, stays diagnosed"; return 1
  elif ! gh_rest_comment "$ST_REPO" "$n" "$bf"; then
    _st_log "$key comment on #$n failed (HTTP ${GH_REST_STATUS:-000}); stays diagnosed"; return 1
  fi
  return 0
}

# _st_writeback <key> <detail> <url>: the ticket link on the Sentry issue, once.
_st_writeback() {
  local key=$1 det=$2 url=$3 id code wb body
  id=$(jq -r '.sentry_id' <<<"$det")
  body="$ST_TMP/wb.json"
  jq -nc --arg u "$url" '{text: ("Tracked in " + $u)}' > "$body"
  code=$(_st_curl "$ST_TMP/wb.out" "$ST_API/issues/$id/comments/" -X POST -H 'Content-Type: application/json' --data-binary "@$body")
  case "$code" in
    2??) wb=ok ;;
    401|403) wb="skipped-$code"; _st_log "sentry token lacks issue:write (HTTP $code); writeback skipped for $id" ;;
    *) wb="failed-$code"; _st_log "writeback failed for $id (HTTP $code): $(head -c 200 "$ST_TMP/wb.out" 2>/dev/null | tr '\n' ' ')" ;;
  esac
  _st_put "$key" ticketed "$det" "$(jq -nc --arg w "$wb" '{writeback: $w}')" \
    || _st_log "ledger put writeback=$wb for $key failed"
}

# _st_act <key> <detail> <issue-json>: act on detail.diagnosis. No model call.
_st_act() {
  local key=$1 det=$2 issue=$3 dg verdict n id perm cnt c24 tf bf rc num url labels now
  dg=$(jq -c '.diagnosis' <<<"$det"); verdict=$(jq -r '.verdict' <<<"$dg")
  id=$(jq -r '.sentry_id' <<<"$det"); perm=$(jq -r '.permalink // ""' <<<"$det")
  cnt=$(jq -r '.count // "0"' <<<"$issue")
  c24=$(jq '[(.stats["24h"] // [])[] | .[1] | numbers] | add // 0' <<<"$issue")
  now=$(date -u -d "@$ST_NOW" +%FT%TZ)
  case "$verdict" in
    noise)
      _st_put "$key" noise "$det" "$(jq -c '{reason: .reason}' <<<"$dg")" \
        || { _st_log "ledger put noise for $key failed"; ST_OUT=skip; return 0; }
      _st_log "$key noise: $(jq -r .reason <<<"$dg")"; ST_OUT=noise ;;
    comment)
      n=$(jq -r '.issue' <<<"$dg"); bf="$ST_TMP/comment.md"
      { jq -r '.comment' <<<"$dg"
        printf '\n#### Evidence\n- Sentry: %s\n- Events: %s total, %s in the last 24 h\n' "$perm" "$cnt" "$c24"
        if [ -s "$ST_TMP/loglines.txt" ]; then printf '\n```\n'; head -n 20 "$ST_TMP/loglines.txt"; printf '```\n'; fi
        printf '\n<!-- sentry-issue: %s -->\n' "$key"
      } | _st_dash > "$bf"
      # A comment posted on an earlier tick whose ticketed put failed: no repost.
      # The first page (100 comments) is read; an unreadable page posts nothing.
      _st_comment_once "$key" "$n" "$bf" "<!-- sentry-issue: $key -->" || { ST_OUT=skip; return 0; }
      # The link comes from the open-issue list, never built.
      url=$(jq -r --argjson n "$n" '[.[] | select(.number == $n) | .html_url // empty][0] // ""' "$ST_OPEN" 2>/dev/null)
      det=$(jq -c --argjson n "$n" --arg u "$url" '. + {action: "commented", issue: $n, url: (if $u == "" then null else $u end)}' <<<"$det")
      _st_save "$key" ticketed "$det" || _st_log "ledger put ticketed for $key failed"
      _st_log "$key commented on #$n"; ST_OUT=commented
      if [ -n "$url" ]; then _st_writeback "$key" "$det" "$url"
      else _st_log "#$n has no html_url in the open list; writeback skipped for $key"; fi ;;
    ticket)
      rc=0; _st_day_capped || rc=$?
      if [ "$rc" = 2 ]; then ST_STOP=ledger; return 75; fi
      if [ "$rc" = 0 ]; then
        _st_log "cap SENTRY_TRIAGE_MAX_TICKETS_DAY=$ST_MAX_DAY reached; $key stays diagnosed"; ST_OUT=capped; return 0
      fi
      tf=$(printf 'Sentry %s: %s' "$(jq -r '.short_id' <<<"$det")" "$(jq -r '.title' <<<"$dg")" | tr '\n' ' ' | _st_dash | token_redact | cut -c1-120)
      bf="$ST_TMP/body.md"
      { printf '#### Cause\n'; jq -r '.cause' <<<"$dg"
        printf '\n#### Evidence\n- Sentry: %s\n- Events: %s total, %s in the last 24 h\n' "$perm" "$cnt" "$c24"
        printf -- '- Tags: %s\n' "$(jq -r '[(.tags // {}) | to_entries[] | "\(.key)=\(.value)"] | join(", ")' "$ST_TMP/event.json" 2>/dev/null)"
        if [ -s "$ST_TMP/loglines.txt" ]; then printf '\n```\n'; head -n 20 "$ST_TMP/loglines.txt"; printf '```\n'; fi
        printf '\n#### Proposed fix\n'; jq -r '.proposed_fix // ""' <<<"$dg"
        printf '\n#### Acceptance tests\n'; jq -r '(.acceptance_tests // []) | if type == "array" then .[] else . end | "- \(.)"' <<<"$dg"
        printf '\n<!-- sentry-issue: %s -->\n' "$key"
      } | _st_dash > "$bf"
      labels='["ai-build"]'; [ "$c24" -gt "$ST_HOTFIX_24H" ] && labels='["ai-build","hotfix"]'
      if ! _st_create "$tf" "$bf" "$labels"; then
        _st_log "$key create failed (HTTP ${GH_REST_STATUS:-000}); stays diagnosed"; ST_OUT=skip; return 0
      fi
      num=$ST_NUM; url=$ST_URL
      det=$(jq -c --argjson n "$num" --arg u "$url" --arg at "$now" '. + {action: "filed", issue: $n, url: $u, filed_at: $at}' <<<"$det")
      _st_save "$key" ticketed "$det" \
        || _st_log "ledger put ticketed for $key failed; the body marker heals it next tick"
      _st_day_filed_add "$id" || true
      _st_log "$key filed #$num $url"; ST_OUT=filed
      _st_writeback "$key" "$det" "$url" ;;
    *)
      _st_put "$key" failed "$det" '{"why":"diagnosis-lost"}' \
        || { _st_log "ledger put failed for $key failed"; ST_OUT=skip; return 0; }
      _st_log "$key stored diagnosis unreadable (verdict '${verdict:0:20}'); failed {why: diagnosis-lost}"; ST_OUT=failed ;;
  esac
  return 0
}

# _st_evidence <issue-json>: THIS issue's latest event and lane log lines in
# $ST_TMP/event.json and $ST_TMP/loglines.txt, and its reason tag in ST_REASON.
# No model call. st_issue removes both files before each issue, so a ticket or
# comment never carries the evidence of another issue.
_st_evidence() {
  local tags lane box at
  st_latest_event "$(jq -r .id <<<"$1")" "$ST_TMP/event.json" || true
  tags=$(jq -c '.tags // {}' "$ST_TMP/event.json" 2>/dev/null) || tags='{}'
  lane=$(jq -r '.lane // ""' <<<"$tags"); box=$(jq -r '.box // ""' <<<"$tags")
  ST_REASON=$(jq -r '.reason // ""' <<<"$tags"); at=$(jq -r '.dateCreated // ""' "$ST_TMP/event.json" 2>/dev/null)
  st_log_lines "$lane" "$box" "$ST_REASON" "$at" > "$ST_TMP/loglines.txt"
}

# _st_prompt <issue-json> <regressed> <pf>: the prompt file. Every outside text
# goes through ui_wrap.
_st_prompt() {
  local issue=$1 reg=$2 pf=$3
  _st_evidence "$issue"
  cands=$(st_candidates "$ST_REASON")
  { cat "$(_st_root)/catalog/prompts/sentry-triage.md"
    if [ -n "${ST_SOURCE_LABEL:-}" ]; then
      printf '\n## Sentry source\n%s/%s (%s)\n' "$ST_ORG" "$ST_PROJECT" "$ST_SOURCE_LABEL"
    fi
    printf '\n%s\n\n## Sentry issue\n' "$(ui_notice)"
    { jq -r --arg r "$reg" '"id: \(.id)\nshort id: \(.shortId)\ntitle: \(.title)\npermalink: \(.permalink)\nevents: \(.count)\nregressed: \($r)"' <<<"$issue"
      printf '\nlatest event:\n'; head -c 12000 "$ST_TMP/event.json"; printf '\n'; } | ui_wrap fetched-page
    printf '\n## Lane log lines\n'
    ui_wrap fetched-page < "$ST_TMP/loglines.txt"
    printf '\n## Candidate open tickets\n'
    if [ "$(jq 'length' <<<"$cands")" = 0 ]; then echo "none"
    else jq -r '.[] | "#\(.number) \(.title)\n\(.body)\n"' <<<"$cands" | ui_wrap ticket-body; fi
  } > "$pf"
}

st_issue() { # st_issue <issue-json>
  local issue=$1 id cnt reg key row rc=0 st det n prior cands='[]' hit pf raw text arc fp root
  ST_OUT=skip; ST_REASON=""
  rm -f "$ST_TMP/event.json" "$ST_TMP/loglines.txt"
  id=$(jq -r '.id // "" | tostring' <<<"$issue")
  if ! [[ $id =~ ^[0-9A-Za-z]+$ ]]; then _st_log "skip an issue with id '${id:0:40}'"; return 0; fi
  cnt=$(jq -r '.count // "" | tostring' <<<"$issue")
  if ! [[ $cnt =~ ^[0-9]+$ ]]; then _st_log "skip $id: count '${cnt:0:20}' is not a number"; return 0; fi
  if [ "$cnt" -lt "$ST_MIN_EVENTS" ]; then ST_OUT=below_min; return 0; fi
  reg=$(jq -r '(.isRegression == true) or (.status == "regressed") or (.substatus == "regressed")' <<<"$issue")

  # The ledger, FIRST. An outage is never "no row".
  key="${ST_KEY_PREFIX:-}$id"
  row=$(job_ledger_row "${ST_LANE:-sentry-triage}" "$key") || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ] || { ST_STOP=ledger; return 75; }
  st=""; [ "$rc" = 0 ] && st=$(jq -r '.status // ""' <<<"$row")
  case "$st" in
    ticketed|noise|failed)
      [ "$reg" = true ] || { ST_OUT=terminal; return 0; }
      # The <id> pass already saw this regression: that was its one pass.
      [ "$(jq -r '.regressed' <<<"$(_st_detail "$row")")" = true ] && { ST_OUT=terminal; return 0; }
      key="${ST_KEY_PREFIX:-}$id:regressed"; rc=0
      row=$(job_ledger_row "${ST_LANE:-sentry-triage}" "$key") || rc=$?
      [ "$rc" = 0 ] || [ "$rc" = 2 ] || { ST_STOP=ledger; return 75; }
      st=""; [ "$rc" = 0 ] && st=$(jq -r '.status // ""' <<<"$row") ;;
  esac
  det='{}'; [ "$rc" = 0 ] && det=$(_st_detail "$row")
  det=$(jq -c --argjson i "$issue" --argjson r "$reg" '. + {sentry_id: ($i.id | tostring), short_id: ($i.shortId // ""), permalink: ($i.permalink // ""), regressed: $r}' <<<"$det")
  n=$(jq -r '.attempts // 0 | numbers' <<<"$det"); [[ $n =~ ^[0-9]+$ ]] || n=0
  case "$st" in
    ticketed|noise|failed) ST_OUT=terminal; return 0 ;;
    retry)
      if [ "$n" -ge "${ST_MAX_ATTEMPTS:-3}" ]; then
        _st_put "$key" failed "$det" '{"why":"attempts"}' || { ST_STOP=ledger; return 75; }
        _st_log "$key failed after $n attempts"; ST_OUT=failed; return 0
      fi ;;
  esac

  # The marker heal: a row lost after a 201. No call.
  st_open_list || { ST_STOP=open-list; return 75; }
  hit=$(jq -r --arg m "<!-- sentry-issue: $key -->" '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | .[0].number // empty' "$ST_OPEN")
  if [ -n "$hit" ]; then
    _st_put "$key" ticketed "$det" "$(jq -nc --argjson n "$hit" '{action: "healed", issue: $n}')" || { ST_STOP=ledger; return 75; }
    _st_log "$key healed from the marker on #$hit"; ST_OUT=healed; return 0
  fi

  if [ "$st" = diagnosed ]; then
    _st_evidence "$issue"
    _st_act "$key" "$det" "$issue"; return
  fi

  # Before the call: the per-call cap, the day cap, the route, the attempt.
  if ! awk -v v="$ST_MAX_USD" 'BEGIN{exit !(v > 0)}'; then
    _st_log "cap off (SENTRY_TRIAGE_MAX_USD=$ST_MAX_USD); $key not triaged"; ST_OUT=capped; return 0
  fi
  rc=0; _st_day_capped || rc=$?
  if [ "$rc" = 2 ]; then ST_STOP=ledger; return 75; fi
  if [ "$rc" = 0 ]; then
    _st_log "cap SENTRY_TRIAGE_MAX_TICKETS_DAY=$ST_MAX_DAY reached; $key not triaged"; ST_OUT=capped; return 0
  fi
  if [ -z "${ST_MODEL:-}" ]; then
    ST_MODEL=$(lane_role_model stage.sentry-triage 2>/dev/null) || ST_MODEL=""
    ST_RUNNER=$(lane_model_ladder stage.sentry-triage 2>/dev/null | awk -F'\t' 'NR==1{print $3}')
  fi
  if [ -z "$ST_MODEL" ] || [ "${ST_RUNNER:-}" != claude ]; then
    _st_log "no route: stage.sentry-triage gives model '${ST_MODEL}' runner '${ST_RUNNER:-}', not claude; $key not triaged"
    ST_OUT=skip; return 0
  fi
  rc=0; _st_day_call || rc=$?
  if [ "$rc" = 2 ]; then ST_STOP=ledger; return 75; fi
  if [ "$rc" = 1 ]; then
    _st_log "cap SENTRY_TRIAGE_MAX_CALLS_DAY=$ST_MAX_CALLS_DAY reached; $key not triaged"; ST_OUT=capped; return 0
  fi
  prior=$det
  det=$(_st_attempt_put "$key" "$det" "$n") \
    || { _st_log "ledger put attempt for $key failed; no call"; ST_STOP=ledger; return 75; }

  pf="$ST_TMP/prompt.md"; raw="$ST_TMP/answer.txt"; : > "$raw"
  _st_prompt "$issue" "$reg" "$pf"
  fp=$(printf 'sentry-triage|%s' "$key" | sha256sum | cut -c1-64)
  root=$(_st_root); arc=0
  AGENT_CALL_LANE=sentry-triage AGENT_CALL_FP="$fp" AGENT_CALL_NO_TOOLS=1 AGENT_CALL_RUNNERS="$ST_RUNNER" AGENT_CALL_BUDGET_USD_SENTRY_TRIAGE="$ST_MAX_USD" "$root/bin/agent-call.sh" sentry-triage fleet "$ST_MODEL" 300 "$raw" "@$pf" >/dev/null 2>&1 || arc=$?
  ST_CALLED=$((ST_CALLED + 1))
  _st_after_call "$key" "$prior" "$det" "$n" "$arc" && return 0
  rc=0; text=$(_st_reply "$raw") || rc=$?
  if [ "$rc" != 0 ]; then
    local why=bad-reply; [ "$rc" = 1 ] && why=empty-reply
    _st_put "$key" failed "$det" "$(jq -nc --arg w "$why" '{why: $w, last_rc: 0}')" || _st_log "ledger put failed for $key failed"
    _st_log "$key $why; failed (billed once, never re-called)"; ST_OUT=failed; return 0
  fi
  det=$(jq -c --argjson d "$text" '. + {diagnosis: $d, last_rc: 0}' <<<"$det")
  _st_save "$key" diagnosed "$det" || _st_log "ledger put diagnosed for $key failed; acting once"
  _st_act "$key" "$det" "$issue"
}

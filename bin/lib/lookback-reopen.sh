#!/bin/bash
# shellcheck shell=bash
# bin/lib/lookback-reopen.sh — the PR and the client's latest comment for each
# reopen item of the lookback bundle. Sourced, never run; defining the two
# functions below is its only effect.
#
# Reader: bin/lookback-collect.sh src_reopen. It reads nothing it writes back.
#   lrd_pr_map <project> <keys-file> <out-tsv>
#     The PR the hub knows for each key (one per line, as in logs/reopens.csv),
#     from GET /api/ticket-status (worker/jobs/src/routes/ticket-status.js
#     pickPr: the newest merged PR, else the newest open one, else the newest).
#     A key is upper-cased once. `#<n>` is sent as issue=<n> and matched back by
#     tickets[].issue; a key that matches ^[A-Z0-9._-]{1,64}$ is sent as key=<K>
#     and matched back by tickets[].key, exactly; any other key is never sent.
#     Writes `<KEY>\t<pr-url>` lines, only for a github.com pull URL.
#     Chunk size: the settings row ticket_status.batch_max (the route refuses
#     more per call). rc 0 every chunk read; rc 1 a chunk (or the project) not
#     read, LRD_WHY says why. A failed chunk maps nothing; the others are kept.
#   lrd_comment <project> <key> <day YYYYMMDD>
#     One JSON {comment: {at, author, text} | null, comment_status}. The source
#     is rr_get (bin/lib/reopen-reason.sh: the reopen_reason ledger row, then
#     the hub mirror), which the caller must have sourced. comment_status:
#       saved       the row's day is <day> and it holds comments: the last
#                   (newest) one is the comment
#       no-comment  the row's day is <day> and it holds no comment
#       unreadable  the board read failed (read unreadable), or the ledger is
#                   unreadable and there is no mirror
#       other-day   the row belongs to a different reopen of the same key
#       none        no row, or reopen-reason.sh is not loaded
# Writers of what it reads: bin/reopen-metrics.sh (rr_capture_rows) for the
# ledger row and mirror; the hub's pr_records for the ticket-status answer.
#
# FAIL-OPEN: no jobs client, an outage or bad JSON never stops the caller; the
# item is emitted with what is known. Seams for tests: the jobs worker through
# JOBS_URL, the settings row through setting_get (bin/lib/jobs/settings.sh).
#
# The harness root is ${HARNESS:-${H:-}} and nothing else (BH-2613).

LRD_WHY=""

# lrd__batch — the chunk size: the settings row ticket_status.batch_max, a
# whole number >= 1. Fallback 20 = the route's own BATCH_MAX_DEFAULT for that
# row (worker/jobs/src/routes/ticket-status.js).
lrd__batch() {
  local v=""
  declare -F setting_get >/dev/null && v=$(setting_get ticket_status.batch_max 2>/dev/null)
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] || v=20
  printf '%s' "$v"
}

# lrd__chunk <project> <keys...> — one request; appends map lines to $LRD__OUT.
# rc 0 read, rc 1 not read (LRD_WHY set).
lrd__chunk() {
  local p="$1" q k resp rc
  shift
  q="project=$p"
  for k in "$@"; do
    if [[ "$k" =~ ^#([0-9]+)$ ]]; then q="$q&issue=${BASH_REMATCH[1]}"; else q="$q&key=$k"; fi
  done
  # _jobs_req in THIS shell: JOBS_HTTP tells an outage from an empty answer.
  _jobs_req GET "/api/ticket-status?$q" >/dev/null; rc=$?
  resp="${JOBS_BODY:-}"
  if [ "$rc" != 0 ] || ! jq -e '.tickets | type == "array"' <<<"$resp" >/dev/null 2>&1; then
    LRD_WHY="ticket-status http=${JOBS_HTTP:-none}"
    return 1
  fi
  jq -r --args '
    .tickets as $t
    | $ARGS.positional[] as $k
    | ([$t[] | select(type == "object")
        | select(if ($k | test("^#[0-9]+$")) then ((.issue // null) | tostring) == ($k | ltrimstr("#"))
                 else (.key // null) == $k end)
        | .pr.url // empty
        | select(type == "string" and test("^https://github\\.com/[^/]+/[^/]+/pull/[0-9]+$"))] | first) as $u
    | select($u != null) | "\($k)\t\($u)"' "$@" <<<"$resp" >> "$LRD__OUT" 2>/dev/null
  return 0
}

lrd_pr_map() {
  local p="${1:-}" keys="${2:-}" out="${3:-}" n k chunk=() failed=0 skipped=0
  LRD_WHY=""
  [ -n "$out" ] || { LRD_WHY="usage"; return 1; }
  : > "$out" || { LRD_WHY="cannot write $out"; return 1; }
  [[ "$p" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || { LRD_WHY="bad project"; return 1; }
  declare -F _jobs_req >/dev/null || { LRD_WHY="jobs client not installed"; return 1; }
  [ -r "$keys" ] || { LRD_WHY="keys unreadable"; return 1; }
  n=$(lrd__batch)
  LRD__OUT="$out"
  while IFS= read -r k; do
    k=$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')
    if [[ "$k" =~ ^#[0-9]{1,12}$ ]] || [[ "$k" =~ ^[A-Z0-9._-]{1,64}$ ]]; then
      chunk+=("$k")
    else
      skipped=$((skipped + 1)); continue
    fi
    if [ "${#chunk[@]}" -ge "$n" ]; then
      lrd__chunk "$p" "${chunk[@]}" || failed=$((failed + 1))
      chunk=()
    fi
  done < <(sort -u "$keys")
  if [ "${#chunk[@]}" -gt 0 ]; then lrd__chunk "$p" "${chunk[@]}" || failed=$((failed + 1)); fi
  if [ "$failed" -gt 0 ]; then
    LRD_WHY="$LRD_WHY ($failed chunk(s) not read)"
    return 1
  fi
  [ "$skipped" -gt 0 ] && LRD_WHY="$skipped malformed key(s) not sent"
  return 0
}

lrd_comment() {
  local p="${1:-}" k="${2:-}" day="${3:-}" d rc
  if ! declare -F rr_get >/dev/null; then echo '{"comment":null,"comment_status":"none"}'; return 0; fi
  d=$(rr_get "$p" "$k" 2>/dev/null); rc=$?
  case "$rc" in
    0) ;;
    1) echo '{"comment":null,"comment_status":"unreadable"}'; return 0 ;;
    *) echo '{"comment":null,"comment_status":"none"}'; return 0 ;;
  esac
  jq -c --arg day "$day" '
    if (.day // "" | tostring) != $day then {comment: null, comment_status: "other-day"}
    elif .read == "unreadable" then {comment: null, comment_status: "unreadable"}
    elif ((.comments // []) | length) == 0 then {comment: null, comment_status: "no-comment"}
    else {comment: (.comments | last | {at, author, text}), comment_status: "saved"} end' <<<"$d" 2>/dev/null \
    || echo '{"comment":null,"comment_status":"unreadable"}'
}

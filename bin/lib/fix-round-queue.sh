#!/bin/bash
# shellcheck shell=bash
# bin/lib/fix-round-queue.sh — BH-2668 (BH-2530.0). The shell client for the
# fix_round_jobs queue (worker/jobs/schema.sql): seven verbs over the worker's
# /api/fix-rounds routes. Sourced, never executed, and only after
# bin/jobs-client.sh is loaded (_jobs_req, _jobs_log, jobs_configured).
#
# NOT A JC_MODULES MODULE. It builds on _jobs_req without editing the jobs
# client, so the ~100 fixture suites that copy jobs-client and bin/lib/jobs/
# stay untouched. Nothing runs at source time: function definitions only.
#
# rc map, per verb: 0 is the documented success, 1 is an outage, a bad answer
# or bad input (no request is made for bad input), 2 is "none", 9 is a 409,
# except the replay a row proves: finish and adopt read the row the worker's
# 409 carries, and a retry whose first answer was lost is rc 0 when that row
# shows the retry's own outcome already landed (BH-2997). A
# 2xx whose body is not the documented JSON is rc 1, never a success, and a
# read that fails prints nothing rather than an empty or zero answer.
#
# record_in and record_out travel as JSON STRINGS holding the record text
# byte-for-byte. They go to jq on stdin, never on argv, so a record over the
# 128 KB argv cap still arrives whole. A record the worker refuses with 413 is
# rc 1 and a log line. It is never truncated.

# _frq_ready — rc 0 when a request can be made. Otherwise one stderr line and
# rc 1, with no request (and so no jobs-client ALERTS line).
_frq_ready() {
  if declare -F _jobs_req >/dev/null 2>&1 && declare -F jobs_configured >/dev/null 2>&1 \
     && jobs_configured && [ -n "${HARNESS_SECRET:-}" ]; then
    return 0
  fi
  echo "fix-round-queue: coordination DB not configured (JOBS_URL or the shared harness key is unset)" >&2
  return 1
}

_frq_bad() { echo "fix-round-queue: $*" >&2; return 1; }

# fix_round_enqueue <p> <ck> <box> <hot> <record-json> <a1..a6> — POST
#   /api/fix-rounds. Prints .job on 201, .job + {duplicate:true} on a duplicate
#   answer (both rc 0). 404, 413 and every other failure are rc 1.
fix_round_enqueue() {
  [ "$#" -eq 11 ] || _frq_bad "fix_round_enqueue needs <p> <ck> <box> <hot> <record-json> <arg1..arg6>, got $# args" || return 1
  local p="$1" ck="$2" box="$3" hot="$4" rec="$5" body rc
  shift 5
  [ -n "$p" ] && [ -n "$ck" ] && [ -n "$box" ] || _frq_bad "fix_round_enqueue: project, cap_key and box must be non-empty" || return 1
  case "$hot" in 0|1) ;; *) _frq_bad "fix_round_enqueue: hotfix must be 0 or 1, got '$hot'"; return 1 ;; esac
  _frq_ready || return 1
  body=$(printf '%s' "$rec" | jq -Rsc --arg p "$p" --arg ck "$ck" --arg box "$box" --arg hot "$hot" \
    '{project:$p, cap_key:$ck, box:$box, hotfix:($hot|tonumber), args:$ARGS.positional,
      record_in:(if . == "" then null else . end)}' --args "$@") || return 1
  # Not in $(...): JOBS_HTTP must survive into this shell to tell a 413.
  _jobs_req POST /api/fix-rounds "$body" >/dev/null; rc=$?
  case "$rc" in
    0) printf '%s' "${JOBS_BODY:-}" | jq -ce 'if (.job|type) == "object"
         then (if .duplicate == true then .job + {duplicate:true} else .job end)
         else error("no job") end' 2>/dev/null || return 1 ;;
    2) _jobs_log "POST /api/fix-rounds 404: worker predates the fix-round routes"; return 1 ;;
    *) [ "${JOBS_HTTP:-}" = 413 ] \
         && _jobs_log "fix_round_enqueue $p $ck: 413 record_in over the worker's 256 KB cap, not queued"
       return 1 ;;
  esac
}

# fix_round_get <p> <ck> [resp-file] — prints the one queued, claimed or done
#   row for the park. rc 2 when there is none (an adopted row is none) or on a
#   404, rc 1 on an outage or an answer that is not a list. With <resp-file> the
#   raw list is also saved there (emptied first), so fix_round_adopted_record can
#   read the adopted rows from the SAME answer instead of a second GET (BH-7630).
fix_round_get() {
  local p="${1:-}" ck="${2:-}" rf="${3:-}" q resp rc row
  [ -z "$rf" ] || : > "$rf"
  [ -n "$p" ] && [ -n "$ck" ] || _frq_bad "fix_round_get needs <project> <cap_key>" || return 1
  _frq_ready || return 1
  q=$(jq -nr --arg p "$p" --arg ck "$ck" '"project=\($p|@uri)&cap_key=\($ck|@uri)&limit=500"') || return 1
  resp=$(_jobs_req GET "/api/fix-rounds?$q"); rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  [ -z "$rf" ] || printf '%s' "$resp" > "$rf"
  row=$(printf '%s' "$resp" | jq -ce --arg ck "$ck" 'if (.fix_round_jobs|type) == "array"
    then ([.fix_round_jobs[] | select(.cap_key == $ck and (.status == "queued" or .status == "claimed" or .status == "done"))][0] // "none")
    else error("not a list") end' 2>/dev/null) || return 1
  [ "$row" = '"none"' ] && return 2
  printf '%s' "$row"
}

# fix_round_adopted_record <p> <ck> [resp-file] — prints the record_out of the
#   NEWEST adopted row for the park (BH-7630: a lane machine's adopt can reach
#   the worker while its record write-back to the hub is lost). rc 2 when there
#   is no adopted row with a record, when the newest one's result is not done
#   (a terminal answer is never handed back to the ladder), or on a 404; rc 1 on an outage or an answer
#   that is not a list. With <resp-file> (written by fix_round_get) it reads that
#   list and makes no request; an empty file is rc 2 (the get saw a 404).
fix_round_adopted_record() {
  local p="${1:-}" ck="${2:-}" rf="${3:-}" q resp rc rec
  [ -n "$p" ] && [ -n "$ck" ] || _frq_bad "fix_round_adopted_record needs <project> <cap_key>" || return 1
  if [ -n "$rf" ]; then
    resp=$(cat "$rf" 2>/dev/null); [ -n "$resp" ] || return 2
  else
    _frq_ready || return 1
    q=$(jq -nr --arg p "$p" --arg ck "$ck" '"project=\($p|@uri)&cap_key=\($ck|@uri)&status=adopted&limit=500"') || return 1
    resp=$(_jobs_req GET "/api/fix-rounds?$q"); rc=$?
    case "$rc" in
      0) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
  fi
  rec=$(printf '%s' "$resp" | jq -re --arg ck "$ck" 'if (.fix_round_jobs|type) == "array"
    then ([.fix_round_jobs[] | select(.cap_key == $ck and .status == "adopted" and (.record_out|type) == "string")]
          | max_by(.id) // {} | if .result == "done" then .record_out // "" else "" end)
    else error("not a list") end' 2>/dev/null) || return 1
  [ -n "$rec" ] || return 2
  printf '%s' "$rec"
}
# fix_round_claim <box> [stale_min] — POST /api/fix-rounds/claim. Prints .job
#   (rc 0). rc 2 none, 9 lost race, 1 outage. stale_min is sent only when it is
#   all digits.
fix_round_claim() {
  local box="${1:-}" stale="${2:-}" body resp rc
  [ -n "$box" ] || _frq_bad "fix_round_claim needs <box>" || return 1
  _frq_ready || return 1
  body=$(jq -nc --arg box "$box" --arg s "$stale" \
    '{box:$box} + (if ($s|test("^[0-9]+$")) then {stale_min:($s|tonumber)} else {} end)') || return 1
  resp=$(_jobs_req POST /api/fix-rounds/claim "$body"); rc=$?
  case "$rc" in
    0) printf '%s' "$resp" | jq -ce '.job | objects' 2>/dev/null || return 1 ;;
    2) return 2 ;;
    9) return 9 ;;
    *) return 1 ;;
  esac
}

# fix_round_finish <id> <box> <result> [record-json] — POST
#   /api/fix-rounds/finish. rc 0 on 2xx, 9 on 409, 1 on 400, 404 or an outage.
#   A 409 is a replay, rc 0 with one jobs-client.log line and no ALERTS line,
#   only when its row is done or adopted, claimed_by is <box> and result is
#   exactly <result>. Any other 409, including one whose body is not a row,
#   stays rc 9.
fix_round_finish() {
  local id="${1:-}" box="${2:-}" result="${3:-}" rec="${4:-}" body rc st
  case "$id" in ''|*[!0-9]*) _frq_bad "fix_round_finish: id must be numeric, got '$id'"; return 1 ;; esac
  [ -n "$box" ] || _frq_bad "fix_round_finish needs <box>" || return 1
  _frq_ready || return 1
  body=$(printf '%s' "$rec" | jq -Rsc --arg id "$id" --arg box "$box" --arg r "$result" \
    '{id:($id|tonumber), box:$box, result:$r} + (if . == "" then {} else {record_out:.} end)') || return 1
  # Not in $(...): JOBS_BODY must survive into this shell to read a 409's row.
  _jobs_req POST /api/fix-rounds/finish "$body" >/dev/null; rc=$?
  case "$rc" in
    0) return 0 ;;
    9) st=$(printf '%s' "${JOBS_BODY:-}" | jq -er --arg box "$box" --arg r "$result" \
         '.job | objects | select((.status == "done" or .status == "adopted")
           and .claimed_by == $box and .result == $r) | .status' 2>/dev/null) || return 9
       JOBS_ALERT=0 _jobs_log "fix_round_finish $id: 409 was a replay (row $st on $box, result matches)"
       return 0 ;;
    *) return 1 ;;
  esac
}

# fix_round_adopt <id> — POST /api/fix-rounds/adopt. Prints .job (rc 0). A 409
#   whose row is adopted is a replay: it prints that .job and is rc 0. Any other
#   409 (the row is queued, claimed or done, or the body is not a row) is rc 9,
#   and every other failure is rc 1. A replayed adopt cannot be told apart from
#   another adopter winning, because the route records no adopter. That is safe
#   only because the resolver is the single adopter on the hub (flock-deduped
#   per tick).
fix_round_adopt() {
  local id="${1:-}" resp rc
  case "$id" in ''|*[!0-9]*) _frq_bad "fix_round_adopt: id must be numeric, got '$id'"; return 1 ;; esac
  _frq_ready || return 1
  resp=$(_jobs_req POST /api/fix-rounds/adopt "$(jq -nc --arg id "$id" '{id:($id|tonumber)}')"); rc=$?
  case "$rc" in
    0) printf '%s' "$resp" | jq -ce '.job | objects' 2>/dev/null || return 1 ;;
    9) printf '%s' "$resp" | jq -ce '.job | objects | select(.status == "adopted")' 2>/dev/null && return 0
       return 9 ;;
    *) return 1 ;;
  esac
}

# fix_round_open_count — prints queued + claimed rows (each read bounded at
#   500). Either read failing, or not answering a list, prints nothing and is
#   rc 1: an outage is never "0 open".
fix_round_open_count() {
  local st resp n total=0
  _frq_ready || return 1
  for st in queued claimed; do
    resp=$(_jobs_req GET "/api/fix-rounds?status=$st&limit=500") || return 1
    n=$(printf '%s' "$resp" | jq -e '.fix_round_jobs | arrays | length' 2>/dev/null) || return 1
    total=$((total + n))
  done
  printf '%s\n' "$total"
}

#!/bin/bash
# bin/lib/pool-state-rows.sh — BH-5001 (BH-4951.2): the Fly pool's
# money-deciding state as pool_* rows on the jobs worker
# (worker/jobs/src/routes/pool-state.js), so a rebuilt or failed-over hub still
# knows which keys are capped, which are terminal and whether the lane is held.
# Sourced, never executed. Defines functions only: sourcing reads, writes and
# prints nothing, never `exit`s, and every function is safe under set -u.
#
# THE FILES STAY. Every writer here is called AFTER its state/pool/<p>/ file
# write, and every reader answers rc 2 (unknown) unless this shell's snapshot
# answered, so the caller reads its file exactly as it did before.
#
# Knob: the settings row `pool_state_rows`, env POOL_STATE_ROWS the documented
# fallback, resolved by _flag_on_row from bin/jobs-client.sh (bin/lib/jobs/
# queue.sh). No client loaded reads as off. Off is today's behaviour byte for
# byte: no request and no log line.
#
#   psr_on                 rc 0 iff the knob is on.
#   psr_load <p> <since>   the ONE GET /api/pool-state, memoized in the CALLING
#                          shell (call it in the main shell, before any reader
#                          runs inside $( ... )). rc 0 when the answer has the
#                          contract shape for <p>, else rc 2 and _PSR_OK=0.
#   Readers over that snapshot — rc 2 when it did not answer:
#     psr_spawn_count <key> [since]  prints the rows for <key> with ts >= since
#     psr_terminal <key>     prints the row json; rc 1 when there is none
#     psr_spawn_hold         prints "<until> <why>"; rc 1 when there is none
#     psr_held_keys          prints one ticket-hold key per line
#   Writers — rc 0 sent, or nothing to send (knob off, no client); rc 3 the
#   worker did not take it (one POOL_STATE_WRITE_FAILED line per shell):
#     psr_spawn_add <p> <key> <ts> [machine]
#     psr_spawn_remove <p> <key> <ts>
#     psr_terminal_put <p> <key> <branch> <sha> <reason> <created_at> [if_absent]
#     psr_terminal_patch <p> <key> head_sha <sha> | clear <why>
#     psr_hold_put <p> <kind> <key> <ticket_id> <until> <why> <first_seen> [if_absent]
#     psr_hold_clear <p> <kind> <key>
#     psr_claim_machine <p> <key> <mid>   NOT gated on the knob: it stamps the
#                          machine onto a build_queue claim, which exists only on
#                          the rows-only path, so its caller gates on ROWS_ONLY.
#                          rc 0 stamped, rc 3 not (409 another machine, 404 no
#                          claim, or no answer).
#   The project spawn-hold FILE, state/pool/<p>/_spawn-hold "<until> <why>",
#   for a caller that is not bin/fly-pool.sh (the console pool_hold command,
#   BH-7708). Not gated on the knob: the file is the hold on this hub.
#     psr_hold_file_put <harness> <p> <until> <why>  rc 0 written, 1 not.
#     psr_hold_file_rm <harness> <p>  prints yes/no (a file was there); rc 1
#                          when the file is still there.
#   psr_fallback_note <p> <what>  ONE `POOL_STATE_FALLBACK <p> <what>` line in
#                          $LOG per shell, when the knob is on.
# Requests go out with JOBS_ALERT=0: every one has a documented answer for "no
# answer" (the file), so the ALERTS page stays with the lanes that need the worker.

_PSR_NAME_RE='^[A-Za-z0-9._-]{1,64}$'
_PSR=0; _PSR_SET=0
_PSR_OK=0; _PSR_JSON=""; _PSR_MEMO=""; _PSR_NOTED=""; _PSR_WNOTED=""
_PSR_MK_OK=0; _PSR_MK_CUT=0; declare -gA _PSR_MKO=()
_PSR_MARKER_RE='^(terminal-noted|terminal-alerted|after-since|after-released|after-loop|cap-wait)$'

psr_on() {
  command -v _flag_on_row >/dev/null 2>&1 || return 1
  _flag_on_row pool_state_rows "${POOL_STATE_ROWS:-0}" _PSR
}

_psr_client() { command -v _jobs_req >/dev/null 2>&1; }

_psr_log() {
  [ -n "${LOG:-}" ] || return 0
  printf '%s [pool/%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${1:-?}" "$2" >> "$LOG" 2>/dev/null
  return 0
}

psr_load() {
  local p="${1:-}" since="${2:-0}" resp rc=0
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  if [ "$_PSR_MEMO" = "$p|$since" ]; then [ "${_PSR_OK:-0}" = 1 ] && return 0; return 2; fi
  _PSR_MEMO="$p|$since"; _PSR_OK=0; _PSR_JSON=""; _PSR_MK_OK=0; _PSR_MK_CUT=0; _PSR_MKO=()
  [[ "$p" =~ $_PSR_NAME_RE ]] || return 2
  _psr_client || return 2
  resp=$(JOBS_ALERT=0 _jobs_req GET "/api/pool-state?project=$p&since=$since" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || return 2
  printf '%s' "$resp" | jq -e --arg p "$p" 'type == "object" and .project == $p
      and (.spawns | type) == "array" and (.terminals | type) == "array" and (.holds | type) == "array"' \
    >/dev/null 2>&1 || return 2
  _PSR_JSON=$resp; _PSR_OK=1
  # BH-7431: `markers` is optional; an older worker answers without it, and
  # then every marker reader reads its file only.
  printf '%s' "$resp" | jq -e '(.markers | type) == "array"' >/dev/null 2>&1 && _PSR_MK_OK=1
  # A cut list may undercount; the caller still takes max(db, file), so this is
  # said, never treated as a fallback.
  if printf '%s' "$resp" | jq -e '.truncated.spawns == true' >/dev/null 2>&1; then
    _psr_log "$p" "POOL_STATE_TRUNCATED $p spawns (the cap count takes the larger of the rows and the file)"
  fi
  if printf '%s' "$resp" | jq -e '.truncated.markers == true' >/dev/null 2>&1; then
    _PSR_MK_CUT=1
    _psr_log "$p" "POOL_STATE_TRUNCATED $p markers (a marker past the cut reads from its file only)"
  fi
  return 0
}

psr_spawn_count() {
  local since="${2:-0}" n
  [ "${_PSR_OK:-0}" = 1 ] || return 2
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  n=$(printf '%s' "$_PSR_JSON" | jq -r --arg k "${1:-}" --argjson s "$since" \
        '[.spawns[] | select(.key == $k and (.ts | tonumber) >= $s)] | length' 2>/dev/null) || return 2
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  printf '%s\n' "$n"
}

psr_terminal() {
  local r
  [ "${_PSR_OK:-0}" = 1 ] || return 2
  r=$(printf '%s' "$_PSR_JSON" | jq -c --arg k "${1:-}" 'first(.terminals[] | select(.key == $k)) // empty' 2>/dev/null) || return 2
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

psr_spawn_hold() {
  local r
  [ "${_PSR_OK:-0}" = 1 ] || return 2
  r=$(printf '%s' "$_PSR_JSON" | jq -r 'first(.holds[] | select(.kind == "spawn")) // empty
        | "\(.until_at // 0) \(.why // "")"' 2>/dev/null) || return 2
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

psr_held_keys() {
  [ "${_PSR_OK:-0}" = 1 ] || return 2
  printf '%s' "$_PSR_JSON" | jq -r '.holds[] | select(.kind == "ticket") | .key' 2>/dev/null || return 2
}

psr_marker() {
  local k="${1:-}" m="${2:-}" o r
  [ "${_PSR_OK:-0}" = 1 ] && [ "${_PSR_MK_OK:-0}" = 1 ] || return 2
  o="${_PSR_MKO[$k|$m]:-}"
  case "$o" in
    -) return 1 ;;
    +*) printf '%s\n' "${o#+}"; return 0 ;;
  esac
  # The `=` prefix tells an empty value from no row.
  r=$(printf '%s' "$_PSR_JSON" | jq -r --arg k "$k" --arg m "$m" \
        'first(.markers[] | select(.key == $k and .marker == $m)) | "=" + (.value // "")' 2>/dev/null) || return 2
  [ -n "$r" ] || return 1
  printf '%s\n' "${r#=}"
}

psr_marker_has() {
  [ -f "${3:-}" ] && return 0
  psr_marker "${1:-}" "${2:-}" >/dev/null
}

psr_marker_read() {
  local v
  if [ -f "${3:-}" ]; then cat "$3" 2>/dev/null; return; fi
  v=$(psr_marker "${1:-}" "${2:-}") || return 1
  printf '%s\n' "$v"
}

psr_fallback_note() {
  psr_on || return 0
  [ -z "$_PSR_NOTED" ] || return 0
  _PSR_NOTED=1
  _psr_log "${1:-?}" "POOL_STATE_FALLBACK ${1:-?} ${2:-pool-state read} — the rows did not answer, this tick reads state/pool/ files"
}

# _psr_send <project> <what> <method> <path> <body> — rc 0 taken, 3 not.
_psr_send() {
  local p="$1" what="$2" rc=0
  JOBS_ALERT=0 _jobs_req "$3" "$4" "$5" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && return 0
  if [ -z "$_PSR_WNOTED" ]; then
    _PSR_WNOTED=1
    _psr_log "$p" "POOL_STATE_WRITE_FAILED $p $what (rc=$rc http=${JOBS_HTTP:-none}) — the file was written; the row was not"
  fi
  return 3
}

# _psr_w — rc 0 when a write should go out.
_psr_w() { psr_on && _psr_client; }

psr_spawn_add() {
  local p="${1:-}" key="${2:-}" ts="${3:-}" m="${4:-}" body
  _psr_w || return 0
  body=$(jq -nc --arg p "$p" --arg k "$key" --arg ts "$ts" --arg b "${JOBS_BOX:-}" --arg m "$m" \
    '{project:$p, rows:[{key:$k, ts:($ts|tonumber), box:$b} + (if $m == "" then {} else {machine:$m} end)]}' 2>/dev/null) || return 3
  _psr_send "$p" "spawn $key" POST /api/pool-state/spawns "$body"
}

psr_spawn_remove() {
  local p="${1:-}" key="${2:-}" ts="${3:-}" body
  _psr_w || return 0
  body=$(jq -nc --arg p "$p" --arg k "$key" --arg ts "$ts" '{project:$p, key:$k, ts:($ts|tonumber)}' 2>/dev/null) || return 3
  _psr_send "$p" "spawn-remove $key" POST /api/pool-state/spawns/remove "$body"
}

psr_terminal_put() {
  local p="${1:-}" key="${2:-}" body
  _psr_w || return 0
  body=$(jq -nc --arg p "$p" --arg k "$key" --arg br "${3:-}" --arg sha "${4:-}" --arg r "${5:-}" \
                --arg c "${6:-}" --arg b "${JOBS_BOX:-}" --arg ia "${7:-}" \
    '{project:$p, key:$k, branch:$br, head_sha:$sha, reason:$r, box:$b}
     + (if $c == "" then {} else {created_at:$c} end)
     + (if $ia == "" then {} else {if_absent:true} end)' 2>/dev/null) || return 3
  _psr_send "$p" "terminal $key" PUT /api/pool-state/terminal "$body"
}

psr_terminal_patch() {
  local p="${1:-}" key="${2:-}" op="${3:-}" v="${4:-}" body
  _psr_w || return 0
  case "$op" in
    head_sha) body=$(jq -nc --arg p "$p" --arg k "$key" --arg s "$v" --arg b "${JOBS_BOX:-}" '{project:$p, key:$k, head_sha:$s, box:$b}') ;;
    clear)    body=$(jq -nc --arg p "$p" --arg k "$key" --arg w "$v" --arg b "${JOBS_BOX:-}" '{project:$p, key:$k, clear:true, why:$w, box:$b}') ;;
    *) return 3 ;;
  esac
  [ -n "$body" ] || return 3
  _psr_send "$p" "terminal-$op $key" PATCH /api/pool-state/terminal "$body"
}

psr_hold_put() {
  local p="${1:-}" kind="${2:-}" key="${3:-}" body
  _psr_w || return 0
  body=$(jq -nc --arg p "$p" --arg kd "$kind" --arg k "$key" --arg t "${4:-}" --arg u "${5:-}" \
                --arg w "${6:-}" --arg f "${7:-}" --arg b "${JOBS_BOX:-}" --arg ia "${8:-}" \
    '{project:$p, kind:$kd, key:$k, why:$w, box:$b}
     + (if $t == "" then {} else {ticket_id:$t} end)
     + (if $u == "" then {} else {until_at:($u|tonumber)} end)
     + (if $f == "" then {} else {first_seen:$f} end)
     + (if $ia == "" then {} else {if_absent:true} end)' 2>/dev/null) || return 3
  _psr_send "$p" "hold-$kind ${key:-project}" PUT /api/pool-state/holds "$body"
}

psr_hold_clear() {
  local p="${1:-}" kind="${2:-}" key="${3:-}" body
  _psr_w || return 0
  body=$(jq -nc --arg p "$p" --arg kd "$kind" --arg k "$key" '{project:$p, kind:$kd, key:$k, clear:true}' 2>/dev/null) || return 3
  _psr_send "$p" "hold-clear-$kind ${key:-project}" PATCH /api/pool-state/holds "$body"
}

psr_marker_put() {
  local p="${1:-}" key="${2:-}" m="${3:-}" v="${4:-}" body
  _psr_w || return 0
  [[ "$m" =~ $_PSR_MARKER_RE ]] || return 3
  _PSR_MKO[$key|$m]="+$v"
  body=$(jq -nc --arg p "$p" --arg k "$key" --arg m "$m" --arg v "$v" --arg b "${JOBS_BOX:-}" \
    '{project:$p, key:$k, marker:$m, value:$v, box:$b}' 2>/dev/null) || return 3
  _psr_send "$p" "marker-$m $key" PUT /api/pool-state/markers "$body"
}

psr_marker_clear() {
  local p="${1:-}" key="${2:-}" m send=() body
  shift 2 2>/dev/null || return 0
  _psr_w || return 0
  for m in "$@"; do
    [[ "$m" =~ $_PSR_MARKER_RE ]] || continue
    # Skip the PATCH only when this tick's full marker list answered and has
    # no row. A failed GET, an older worker or a cut list cannot prove the row
    # is gone, and a row left behind reads as live through the union readers.
    if [ "${_PSR_MK_CUT:-0}" = 1 ] || [[ "${_PSR_MKO[$key|$m]:-}" == +* ]]; then send+=("$m")
    else psr_marker "$key" "$m" >/dev/null; [ $? -eq 1 ] || send+=("$m"); fi
    [ "${_PSR_OK:-0}" = 1 ] && _PSR_MKO[$key|$m]="-"
  done
  [ "${#send[@]}" -gt 0 ] || return 0
  body=$(jq -nc --arg p "$p" --arg k "$key" '{project:$p, key:$k, markers:$ARGS.positional, clear:true}' \
    --args "${send[@]}" 2>/dev/null) || return 3
  _psr_send "$p" "marker-clear $key" PATCH /api/pool-state/markers "$body"
}

_psr_hold_file() { # <harness> <p> -> the path; rc 1 on a bad project name
  [[ "${2:-}" =~ $_PSR_NAME_RE ]] && [[ "$2" != *..* ]] || return 1
  [ -n "${1:-}" ] || return 1
  printf '%s/state/pool/%s/_spawn-hold\n' "$1" "$2"
}

psr_hold_file_put() {
  local f
  f=$(_psr_hold_file "${1:-}" "${2:-}") || return 1
  [[ "${3:-}" =~ ^[0-9]+$ ]] || return 1
  mkdir -p "${f%/*}" 2>/dev/null
  { printf '%s %s\n' "$3" "${4:-}" > "$f.$$" && mv "$f.$$" "$f"; } 2>/dev/null \
    || { rm -f "$f.$$" 2>/dev/null; return 1; }
}

psr_hold_file_rm() {
  local f had=no
  f=$(_psr_hold_file "${1:-}" "${2:-}") || return 1
  [ -e "$f" ] && had=yes
  rm -f "$f" 2>/dev/null
  printf '%s\n' "$had"
  [ ! -e "$f" ]
}

psr_claim_machine() {
  local p="${1:-}" key="${2:-}" mid="${3:-}" body
  _psr_client || return 0
  body=$(jq -nc --arg p "$p" --arg k "$key" --arg m "$mid" --arg b "${JOBS_BOX:-}" \
    '{project:$p, key:$k, machine:$m, box:$b}' 2>/dev/null) || return 3
  JOBS_ALERT=0 _jobs_req PUT /api/pool-state/claim-machine "$body" >/dev/null 2>&1 || return 3
}

#!/bin/bash
# bin/lib/mc-hold-comment.sh — HOLD COMMENTS (BH-3452 contract, part of BH-3436).
# Sourced by bin/merge-conductor.sh, never executed.
#
# One PR comment per (PR, kind) saying why the merge conductor is not queueing
# the PR and what clears it (BH-3455). Nothing calls it yet: the sibling slices
# of BH-3436 wire it into the conductor. The interface:
#
# mc_hold_comment <key> <head> <kind> <reason>
#   <key> is owner/repo#n, <kind> one of the kinds below. Returns 0 at once when
#   the knob MC_HOLD_COMMENT (lib.hold-comment) is 0. Otherwise, when
#   MC_HOLD_COMMENT_TRACE names a file, appends key<TAB>head<TAB>kind<TAB>reason
#   to it (the test seam). Always returns 0: it never fails the caller.
#
# mc_hold_comment_clears <kind>
#   Prints the line saying what clears a hold of that kind and returns 0.
#   Prints nothing and returns 1 for any other kind. The kinds: ticket-hold,
#   pr-hold, hold-label, lead, lead-mergify, dep-hold, hotfix, tightened,
#   provenance, iron-law, migration.
#
# The root comes from MC_H, HARNESS or H only; with none of them set the source
# returns 1 and defines nothing.

_hc_root="${MC_H:-${HARNESS:-${H:-}}}"
[ -n "$_hc_root" ] || return 1

# The knob, once per source: lane-gate's lib_env_apply in a subshell, so a
# settings row reaches it. No row, no worker: the env stays as it was.
_hc_v=$(
  command -v lib_env_apply >/dev/null 2>&1 || . "$_hc_root/bin/lib/lane-gate.sh" >/dev/null 2>&1
  lib_env_apply hold-comment >/dev/null 2>&1
  printf '%s' "${MC_HOLD_COMMENT:-}"
) 2>/dev/null
[ -n "$_hc_v" ] && MC_HOLD_COMMENT=$_hc_v
unset _hc_v

# What one call does, after the knob and the trace:
#  1. A kind mc_hold_comment_clears does not know posts nothing, and neither
#     does a key that is not owner/repo#n.
#  2. The dedupe id is <owner/repo lowercased>#<n>@<kind>. The head is not in
#     it: a hold that outlives a push is the same hold, so one comment.
#  3. Observe (ACTIONS!=1) or kill (KILL=1): one WOULD line per id, kept in its
#     own file so a WOULD never reads as posted. Nothing is sent.
#  4. The status comes from $MC_STATE_DIR/hold-comments.txt first (no network),
#     then the job ledger (kind hold_comment). Both unreadable: skip the tick.
#     posted, and failed-<n> at HC_MAX_FAILS, are terminal.
#  5. Under a per-id flock -n (dedupe, never a queue) the status is read again.
#     A posting row read there was left by a crashed sender, so the thread is
#     read for the kind's marker before anything is sent again.
#  6. posting is written BEFORE the POST, posted only on a 2xx, failed-<n>
#     otherwise; the HC_MAX_FAILS-th failure logs one give-up line.
#  7. After a post, a READY-row kind also calls mc_ready_why once. _MC_HC_IN
#     stops a call back into here from calling it again.
HC_MAX_FAILS=3
HC_REASON_MAX=300
HC_READY_KINDS=" ticket-hold pr-hold hold-label lead lead-mergify dep-hold hotfix "

_hc_state() { printf '%s' "${MC_STATE_DIR:-$_hc_root/state/merge-conductor}"; }
_hc_file() { printf '%s/hold-comments.txt' "$(_hc_state)"; }
_hc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_hc_log() { command -v mc_log >/dev/null 2>&1 && mc_log "$*"; return 0; }

# _hc_file_status <hid> — the last status the file holds for hid, if any.
_hc_file_status() {
  awk -v h="$1" '$1==h {s=$2} END {if (s!="") print s}' "$(_hc_file)" 2>/dev/null
}
# _hc_since <hid> — the timestamp on hid's last posting line, if any.
_hc_since() {
  awk -v h="$1" '$1==h && $2=="posting" {s=$3} END {if (s!="") print s}' "$(_hc_file)" 2>/dev/null
}
# _hc_status <hid> — rc 0 prints the status (file first, then the ledger);
# rc 2 a miss in both; rc 1 unreadable (no file line, no ledger answer).
_hc_status() {
  local st rc=1
  st=$(_hc_file_status "$1")
  [ -n "$st" ] && { printf '%s' "$st"; return 0; }
  if command -v job_ledger_get >/dev/null 2>&1; then st=$(job_ledger_get hold_comment "$1"); rc=$?; fi
  [ "$rc" = 0 ] && [ -n "$st" ] && { printf '%s' "$st"; return 0; }
  [ "$rc" = 2 ] && return 2
  return 1
}
# _hc_fails <hid> [status] — failed posts: the larger of the n a failed-<n>
# status carries and the file's failed lines, so a failed-<n> that reached
# only one of the two stores still counts.
_hc_fails() {
  local f n=0
  f=$(awk -v h="$1" '$1==h && $2 ~ /^failed/ {n++} END {print n+0}' "$(_hc_file)" 2>/dev/null)
  case "${2:-}" in failed-*) n="${2#failed-}" ;; esac
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$f" in ''|*[!0-9]*) f=0 ;; esac
  [ "$f" -gt "$n" ] && n="$f"
  echo "$n"
}
# _hc_go <key> <kind> <hid> <status> <status-rc> — rc 0 when a send may go ahead.
_hc_go() {
  case "$5" in
    0) ;;
    2) return 0 ;;
    *) _hc_log "HOLD_COMMENT $1 $2 skipped: ledger and file both unreadable, nothing sent this tick"; return 1 ;;
  esac
  case "$4" in
    posted) return 1 ;;
    failed-*) [ "$(_hc_fails "$3" "$4")" -lt "$HC_MAX_FAILS" ] ;;
    *) return 0 ;;
  esac
}
# _hc_detail <head> <kind> [extra-json] — the ledger row's detail.
_hc_detail() {
  local x="${3:-}"
  [ -n "$x" ] || x='{}'
  jq -nc --arg h "$1" --arg k "$2" --arg a "$(_hc_now)" --argjson x "$x" '{head:$h,kind:$k,at:$a} + $x' 2>/dev/null
}
# _hc_record <hid> <status> <head> <detail-json> — ledger + file line
# `<hid> <status> <iso> <head8>`; rc 1 only when BOTH writes failed.
_hc_record() {
  local lrc=1 frc=1 h8="${3:0:8}"
  if command -v job_ledger_put >/dev/null 2>&1; then job_ledger_put hold_comment "$1" "$2" "$4" && lrc=0; fi
  mkdir -p "$(_hc_state)" 2>/dev/null
  { printf '%s %s %s %s\n' "$1" "$2" "$(_hc_now)" "${h8:--}" >> "$(_hc_file)"; } 2>/dev/null && frc=0
  [ "$lrc" = 0 ] || [ "$frc" = 0 ]
}
# _hc_body <kind> <reason> <clear> — the two lines posted. The reason is
# flattened onto the second line, so no line of the body starts with a word
# the block gate or the hold readers act on: they are line-anchored, and the
# PAT posts as a User, so they do read this comment.
_hc_body() {
  local r="${2:-}"
  r=${r//$'\r'/ }; r=${r//$'\n'/ }; r=${r//$'\t'/ }
  r=${r//' — '/, }; r=${r//—/, }; r=${r//–/, }
  while [[ $r == *'  '* ]]; do r=${r//'  '/ }; done
  r=${r# }
  r=${r:0:$HC_REASON_MAX}
  while :; do case "$r" in *' '|*.) r=${r%?} ;; *) break ;; esac; done
  printf '<!-- bh-hold-comment:%s -->\n' "$1"
  if [ -n "$r" ]; then
    printf "We're not queueing this PR yet. Reason: %s. What clears it: %s. The merge conductor picks it up on its next pass once that happens." "$r" "$3"
  else
    printf "We're not queueing this PR yet. What clears it: %s. The merge conductor picks it up on its next pass once that happens." "$3"
  fi
}
# _hc_send <key> <head> <kind> <hid> <slug> <num> <body> — runs under the
# lock. rc 0 only when this call posted the comment.
_hc_send() {
  local st rc since t found n
  st=$(_hc_status "$4"); rc=$?
  _hc_go "$1" "$3" "$4" "$st" "$rc" || return 1
  command -v mc_issue_comment >/dev/null 2>&1 || return 1
  if [ "$rc" = 0 ] && [ "$st" = posting ]; then
    command -v mc_rest_pages >/dev/null 2>&1 || return 1
    since=$(_hc_since "$4")
    t=$(mc_rest_pages "repos/$5/issues/$6/comments${since:+?since=$since}") \
      || { _hc_log "HOLD_COMMENT $1 $3 skipped: a posting row and the thread is unreadable, nothing sent this tick"; return 1; }
    found=$(jq -r --arg m "<!-- bh-hold-comment:$3 -->" \
      'if type == "array" then any(.[]; (.body // "") | tostring | contains($m)) else "bad" end' <<<"$t" 2>/dev/null)
    case "$found" in
      true)
        _hc_record "$4" posted "$2" "$(_hc_detail "$2" "$3" '{"recovered":true}')"
        _hc_log "HOLD_COMMENT $1 $3 a crashed send had landed (marker on the thread), recorded posted, nothing sent again"
        return 1 ;;
      false) ;;
      *) _hc_log "HOLD_COMMENT $1 $3 skipped: a posting row and the thread did not parse, nothing sent this tick"; return 1 ;;
    esac
  fi
  if ! _hc_record "$4" posting "$2" "$(_hc_detail "$2" "$3")"; then
    _hc_log "HOLD_COMMENT $1 $3 skipped: the posting row could not be written (ledger and file both refused), nothing sent"
    return 1
  fi
  GH_REST_STATUS=
  if mc_issue_comment "$5" "$6" "$7"; then
    _hc_record "$4" posted "$2" "$(_hc_detail "$2" "$3")" \
      || _hc_log "HOLD_COMMENT $1 $3 posted but the posted row could not be written, the posting row resolves next pass"
    _hc_log "HOLD_COMMENT $1 $3"
    return 0
  fi
  n=$(( $(_hc_fails "$4" "$st") + 1 ))
  _hc_record "$4" "failed-$n" "$2" "$(_hc_detail "$2" "$3" \
    "$(jq -nc --arg r "HTTP ${GH_REST_STATUS:-000}" --argjson n "$n" '{reason:$r,attempts:$n}' 2>/dev/null)")"
  if [ "$n" -ge "$HC_MAX_FAILS" ]; then
    _hc_log "HOLD_COMMENT $1 $3 gave up after $n failed posts (HTTP ${GH_REST_STATUS:-000}), no more sends for this PR and kind"
  else
    _hc_log "HOLD_COMMENT $1 $3 post failed (HTTP ${GH_REST_STATUS:-000}, attempt $n of $HC_MAX_FAILS)"
  fi
  return 1
}

mc_hold_comment() {
  [ "${MC_HOLD_COMMENT:-}" = 0 ] && return 0
  if [ -n "${MC_HOLD_COMMENT_TRACE:-}" ]; then
    { printf '%s\t%s\t%s\t%s\n' "${1-}" "${2-}" "${3-}" "${4-}" >> "$MC_HOLD_COMMENT_TRACE"; } 2>/dev/null
  fi
  local key="${1-}" head="${2-}" kind="${3-}" reason="${4-}" clear slug num hid wf st rc lk
  clear=$(mc_hold_comment_clears "$kind") || return 0
  case "$key" in *'#'*) ;; *) return 0 ;; esac
  slug=${key%#*}; num=${key##*#}
  case "$num" in ''|*[!0-9]*) return 0 ;; esac
  [[ $slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
  hid="${slug,,}#$num@$kind"

  if [ "${ACTIONS:-0}" != 1 ] || [ "${KILL:-0}" = 1 ]; then
    wf="$(_hc_state)/hold-comments-would.txt"
    grep -qxF -- "$hid" "$wf" 2>/dev/null && return 0
    mkdir -p "$(_hc_state)" 2>/dev/null
    { printf '%s\n' "$hid" >> "$wf"; } 2>/dev/null && _hc_log "HOLD_COMMENT WOULD $key $kind"
    return 0
  fi

  st=$(_hc_status "$hid"); rc=$?
  _hc_go "$key" "$kind" "$hid" "$st" "$rc" || return 0

  lk="$_hc_root/locks/hold-comment-${hid//[^A-Za-z0-9._-]/_}.lock"
  mkdir -p "${lk%/*}" 2>/dev/null
  { : >> "$lk"; } 2>/dev/null || return 0
  rc=0
  (
    flock -n 9 || exit 1
    _hc_send "$key" "$head" "$kind" "$hid" "$slug" "$num" "$(_hc_body "$kind" "$reason" "$clear")"
  ) 9>>"$lk" || rc=$?
  [ "$rc" = 0 ] || return 0

  case "$HC_READY_KINDS" in *" $kind "*) ;; *) return 0 ;; esac
  if [ -z "${_MC_HC_IN:-}" ] && command -v mc_ready_why >/dev/null 2>&1; then
    _MC_HC_IN=1
    mc_ready_why "$key" "$head" "$kind" "$reason"
    unset _MC_HC_IN
  fi
  return 0
}

mc_hold_comment_clears() {
  case "${1-}" in
    ticket-hold)  echo "RESUME on the ticket" ;;
    pr-hold)      echo "RESUME on this PR" ;;
    hold-label)   echo "remove the hold label" ;;
    lead)         echo "a lead or human MERGE on this head" ;;
    lead-mergify) echo "the lead lands it; a label cannot pin the head" ;;
    dep-hold)     echo "the named dependency closes" ;;
    hotfix)       echo "the hotfix migration proof" ;;
    tightened)    echo "the repo's review-tighten park is lifted" ;;
    provenance)   echo "a claude head-bound re-review of this head" ;;
    iron-law)     echo "the flagged lines removed, or a lead MERGE on this head" ;;
    migration)    echo "the named migrations applied in production, then the conductor re-checks on its next pass" ;;
    *) return 1 ;;
  esac
}

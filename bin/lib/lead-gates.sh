#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.sh — BH-5873 (BH-5870.0): the gate loader of the lead
# review worklist. bin/lead-review.sh sources it, and calls it only for a
# worklist item that has no request row (a request row was gated by the
# enqueue, or is a person's ask). Sourced, never run. Private names are _lgt_*
# (bin/lib/lane-gate.sh owns _lg_*).
#
# Gates live one file a gate in bin/lib/lead-gates.d/*.sh. On the first call the
# loader sources them in FILENAME order and records the functions each file
# defines, by prefix:
#   lg_gate_<name> <slug> <pr> <head>   rc 0 pass | 10 skip | 11 hold | 12 decided
#                                       (any other rc = hold, one log line). It may
#                                       set LG_MODE (full|delta|replay).
#   lg_tick_<name> <slug>               once a tick for each worklist repo. Fail-open.
#   lg_post_<name> <slug> <pr> <head>   after the review claimed its row. Fail-open.
#   lg_field_<name> <slug> <pr> <head>  prints the job meta value for key <name>.
# A gate file is sourced inside a function: its own arrays need `declare -g`.
#
#   lg_run <slug> <pr> <head>   every gate in order, stops at the first non-zero.
#       rc 0 = start the review with LG_MODE; 10 or 12 = skip; 11 = hold.
#       lead-gates.d missing or with no gate file, a gate file that fails to
#       source, or LG_MODE outside full|delta|replay = 11 (fail closed).
#   lg_tick <slug>              every lg_tick_*; always rc 0.
#   lg_post <slug> <pr> <head>  every lg_post_*; always rc 0.
#   lg_job_fields <slug> <pr> <head>  one JSON object, key <name> = the
#       function's stdout as a string (empty stdout = no key). rc 1 when a field
#       function fails or the gates did not load.
#   lg_scope_notes <head> <fields-json>  the scope_notes of the worklist start
#       (BH-5878), from lg_job_fields' object, in the order the enqueue
#       writes them: `auto: <reqfor, else builder APPROVE> on <sha12>`, then the
#       fields delta_note, dup_note, prev_note, silence_note, self_check_notes,
#       traced_note, stepdone_note and probe_note that are set, joined by "; ".
#       `review-tier:`/`review-mode:` in those groups become `=` (the readers
#       trust only the last group). The text before the tokens fits 4000 chars
#       less the tokens (lpv_fit first, then a cut), and a review_tokens field
#       that matches `review-tier:<low|medium|high> review-mode:<full|intent>`
#       ends the notes. Always rc 0.
# Logs go to the caller's `log` when it has one, else stderr.

_LGT_LOADED="" _LGT_GATES=() _LGT_TICKS=() _LGT_POSTS=() _LGT_FIELDS=()
declare -A _LGT_SAID=()
LG_MODE=full

_lgt_log() { if declare -F log >/dev/null; then log "$*"; else printf '%s\n' "$*" >&2; fi; }
# _lgt_once <key> <line> — one log line a key a process.
_lgt_once() { [ -n "${_LGT_SAID[$1]:-}" ] && return 0; _LGT_SAID[$1]=1; _lgt_log "$2"; }

_lgt_load() {
  local before after fn n=0
  [ -n "$_LGT_LOADED" ] && { [ "$_LGT_LOADED" = ok ]; return; }
  _LGT_LOADED=bad
  if [ ! -d "${BASH_SOURCE[0]%/*}/lead-gates.d" ]; then
    _lgt_once nodir "bin/lib/lead-gates.d missing; every worklist head is held"; return 1
  fi
  before=$(compgen -A function | sort)
  for _lgt_f in "${BASH_SOURCE[0]%/*}"/lead-gates.d/*.sh; do
    [ -f "$_lgt_f" ] || continue
    n=$((n + 1))
    # shellcheck source=/dev/null
    if ! . "$_lgt_f"; then
      _lgt_once badfile "gate file bin/lib/lead-gates.d/${_lgt_f##*/} failed to source; every worklist head is held"; return 1
    fi
    after=$(compgen -A function | sort)
    while IFS= read -r fn; do
      case "$fn" in
        lg_gate_*) _LGT_GATES+=("$fn") ;; lg_tick_*) _LGT_TICKS+=("$fn") ;;
        lg_post_*) _LGT_POSTS+=("$fn") ;; lg_field_*) _LGT_FIELDS+=("$fn") ;;
      esac
    done < <(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
    before=$after
  done
  [ "$n" -gt 0 ] || { _lgt_once nofile "bin/lib/lead-gates.d has no gate file; every worklist head is held"; return 1; }
  _LGT_LOADED=ok
}

lg_run() {
  local fn rc
  LG_MODE=full
  _lgt_load || return 11
  for fn in "${_LGT_GATES[@]}"; do
    rc=0; "$fn" "$1" "$2" "$3" || rc=$?
    case "$rc" in
      0) ;;
      10|11|12) return "$rc" ;;
      *) _lgt_log "gate $fn answered rc $rc; held"; return 11 ;;
    esac
  done
  case "$LG_MODE" in full|delta|replay) return 0 ;; esac
  _lgt_log "LG_MODE='$LG_MODE' after the gates of $1#$2 is not full|delta|replay; held"
  return 11
}

lg_tick() {
  local fn rc
  _lgt_load || return 0
  for fn in "${_LGT_TICKS[@]}"; do
    rc=0; "$fn" "$1" || rc=$?
    [ "$rc" -eq 0 ] || _lgt_log "tick hook $fn answered rc $rc for $1"
  done
  return 0
}

lg_post() {
  local fn rc
  _lgt_load || return 0
  for fn in "${_LGT_POSTS[@]}"; do
    rc=0; "$fn" "$1" "$2" "$3" || rc=$?
    [ "$rc" -eq 0 ] || _lgt_log "post hook $fn answered rc $rc for $1#$2"
  done
  return 0
}

lg_job_fields() {
  local fn v out='{}'
  _lgt_load || return 1
  for fn in "${_LGT_FIELDS[@]}"; do
    v=$("$fn" "$1" "$2" "$3") || return 1
    [ -n "$v" ] || continue
    out=$(jq -c --arg k "${fn#lg_field_}" --arg v "$v" '. + {($k): $v}' <<<"$out") || return 1
  done
  printf '%s\n' "$out"
}

lg_scope_notes() {
  local f="${2:-}" notes k v tok max
  [ -n "$f" ] || f='{}'
  v=$(jq -r '.reqfor // empty' <<<"$f" 2>/dev/null)
  notes="auto: ${v:-builder APPROVE} on ${1:0:12}"
  for k in delta_note dup_note prev_note silence_note self_check_notes traced_note stepdone_note probe_note; do
    v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$f" 2>/dev/null)
    [ -n "$v" ] && notes="$notes; $v"
  done
  notes="${notes//review-tier:/review-tier=}"; notes="${notes//review-mode:/review-mode=}"
  tok=$(jq -r '.review_tokens // empty' <<<"$f" 2>/dev/null)
  [[ "$tok" =~ ^review-tier:(low|medium|high)\ review-mode:(full|intent)$ ]] || tok=""
  max=4000; [ -n "$tok" ] && max=$((4000 - ${#tok} - 2))
  command -v lpv_fit >/dev/null 2>&1 && notes=$(lpv_fit "$notes" "$max")
  [ "${#notes}" -le "$max" ] || notes="${notes:0:$max}"
  printf '%s' "$notes${tok:+; $tok}"
}

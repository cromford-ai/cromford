#!/bin/bash
# bin/lib/flow-agent/act.sh — flow_act <record-file> <code> (BH-9924 slice
# BH-9956). Sourced by bin/flow-agent.sh after bin/lib/jobs/flow-agent.sh,
# gates.sh and diagnose.sh, never run. No output at source time, `set -u` safe.
#
# THE ORDER, and nothing runs out of it:
#   1 flow_gates <record> <code>. Any answer but `pass` is outcome held: no
#     claim, no arm, and the log line carries gate=<word>.
#   2 held, inputs_unreadable, not_stalled and unknown take no arm (outcome
#     no-arm). unknown calls flow_diagnose <record> once.
#   3 mode log (fa_mode), or flow_agent.action.<code> not 1: fa_claim on the
#     WOULD key (sha256 of p|KEY|code|episode|would). 200 is outcome would,
#     409 already, an outage could-not-claim. No arm runs.
#   4 else fa_claim on the act key (sha256 of p|KEY|code|episode). 409 is
#     already, an outage could-not-claim, and both stop: NO ARM WITHOUT A CLAIM.
#   5 arms/<code>.sh, flow_arm_<code> <record>: rc 0 done, 3 refused, any other
#     rc failed. Its stdout is the detail. A code with no arm is refused no-arm.
#     The arm may set FLOW_ARM_AFTER to the state string after its action.
#   6 fa_record <key> <outcome> <after> <detail>. A failure logs record-lost
#     <key12>: the row stays claimed, so the next pass gets 409 and never
#     repeats the arm.
#   7 one log line in logs/flow-agent.log:
#     <UTC> act <p> <KEY> code=<c> action=<c> outcome=<o> before=<b> after=<a>[ gate=<g>][ note=<n>]
# The outcome word is printed on stdout for the lane's counters.
_FA_ACT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

# fa_state <record-file> — verdict:<v>,queue:<s>,job:<0|1>,pr:<n|none>, no spaces.
fa_state() {
  jq -r '"verdict:\(.verdict // "none"),queue:\(.queue.status // "none"),job:\(if .live_job == true then 1 else 0 end),pr:\(.open_pr.number // "none")"
         | gsub("[^A-Za-z0-9:,_.#-]"; "_")' "$1" 2>/dev/null
}

# fa_log <line...> — one UTC-stamped line in <root>/logs/flow-agent.log.
fa_log() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$root/logs/flow-agent.log" 2>/dev/null
  return 0
}

flow_act() {
  local rec="${1:-}" code="${2:-}" p k ep before after g mode on dk out o arc tmp note=""
  p=$(jq -r '.project // empty' "$rec" 2>/dev/null); k=$(jq -r '.key // empty' "$rec" 2>/dev/null)
  ep=$(jq -r '.episode // empty' "$rec" 2>/dev/null)
  [ -n "$p" ] && [ -n "$k" ] && [ -n "$ep" ] && [ -n "$code" ] || { echo could-not-act; return 0; }
  before=$(fa_state "$rec"); before="${before:-unreadable}"; after="$before"
  _fa_act_line() { fa_log "act $p $k code=$code action=$code outcome=$1 before=$before after=$after${2:+ $2}"; echo "$1"; }

  g=$(flow_gates "$rec" "$code" 2>/dev/null) || g="unreadable"
  if [ "$g" != pass ]; then _fa_act_line held "gate=$(printf '%s' "${g:-none}" | tr -c 'A-Za-z0-9:_.-' '_')"; return 0; fi
  case "$code" in
    held|inputs_unreadable|not_stalled) _fa_act_line no-arm; return 0 ;;
    unknown) flow_diagnose "$rec"; _fa_act_line no-arm; return 0 ;;
  esac

  mode=$(fa_mode "$p") || mode=log
  on=$(setting_get "flow_agent.action.$code" 2>/dev/null) || on=""
  if [ "$mode" != act ] || [ "$on" != 1 ]; then
    dk=$(fa_decision_key "$p" "$k" "$code" "$ep" would)
    fa_claim "$dk" "$p" "$k" "$code" "$code" "$ep" would "$before" >/dev/null
    case $? in
      0) _fa_act_line would ;;
      9) _fa_act_line already ;;
      *) _fa_act_line could-not-claim ;;
    esac
    return 0
  fi

  dk=$(fa_decision_key "$p" "$k" "$code" "$ep")
  fa_claim "$dk" "$p" "$k" "$code" "$code" "$ep" claimed "$before" >/dev/null
  case $? in
    0) ;;
    9) _fa_act_line already; return 0 ;;
    *) _fa_act_line could-not-claim; return 0 ;;
  esac

  if ! declare -F "flow_arm_$code" >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$_FA_ACT_DIR/arms/$code.sh" 2>/dev/null
  fi
  FLOW_ARM_AFTER=""
  tmp=$(mktemp "${TMPDIR:-/tmp}/fa-arm.XXXXXX") || tmp=/dev/null
  if declare -F "flow_arm_$code" >/dev/null 2>&1; then
    arc=0; "flow_arm_$code" "$rec" > "$tmp" 2>/dev/null || arc=$?
    out=$(tr '\n' ' ' < "$tmp" 2>/dev/null | sed 's/ *$//')   # the worker cuts it to flow_agent.evidence_max_chars
  else
    arc=3; out="no-arm"
  fi
  [ "$tmp" = /dev/null ] || rm -f "$tmp"
  case "$arc" in 0) o=done ;; 3) o=refused ;; *) o=failed ;; esac
  [ -n "$FLOW_ARM_AFTER" ] && after=$(printf '%s' "$FLOW_ARM_AFTER" | tr -c 'A-Za-z0-9:,_.#-' '_')
  if ! fa_record "$dk" "$o" "$after" "$out" >/dev/null; then note="note=record-lost:${dk:0:12}"; fi
  _fa_act_line "$o" "$note"
  return 0
}

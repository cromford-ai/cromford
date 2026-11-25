#!/bin/bash
# bin/lib/flow-agent/cause.sh — flow_cause < record: the cause code of one
# record from bin/lib/flow-agent/collect.sh (BH-9924 slice BH-9956). Sourced by
# bin/flow-agent.sh, never run. No output at source time, `set -u` safe.
#
# FLOW_CODES is the ordered code list. For each code, rules/<code>.sh is
# sourced and flow_rule_<code> <record-file> called. A rule answers:
#   rc 0  match       rc 1  no match       rc 2  an input it needs is unread
# The FIRST match wins and is printed. With no match:
#   any rc 2 (or a rule file that does not load)   -> inputs_unreadable
#   else the record is in normal flow              -> not_stalled
#   else                                           -> unknown
# Normal flow: an active queue row (queued, ready or claimed), an open PR, a
# parked job, verdict hold, no current verdict (the untriaged-wake lane owns
# those), or a ticket that changed less than flow_agent.stall_min minutes ago.
FLOW_CODES="answered_not_retriaged ready_not_queued row_for_archived_ticket waits_behind_green_pr waits_behind_dead_blocker parent_slices_not_filed dependency_not_done_but_on_staging pr_conflict pr_red_same_test_as_main"
FA_STALL_MIN_DEFAULT=20   # settings row flow_agent.stall_min; env FLOW_AGENT_STALL_MIN overrides this fallback
_FA_CAUSE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

# fa_stall_min — the stall window in minutes: the settings row, else
# FLOW_AGENT_STALL_MIN, else 20. Read once per process.
fa_stall_min() {
  if [ -z "${_FA_STALL_MIN:-}" ]; then
    _FA_STALL_MIN=$(fa_knob flow_agent.stall_min "${FLOW_AGENT_STALL_MIN:-$FA_STALL_MIN_DEFAULT}")
    [[ "$_FA_STALL_MIN" =~ ^[0-9]+$ ]] || _FA_STALL_MIN=$FA_STALL_MIN_DEFAULT
  fi
  printf '%s\n' "$_FA_STALL_MIN"
}

# _fa_normal_flow <record-file> — rc 0 when the record is in normal flow.
_fa_normal_flow() {
  jq -e --argjson s "$(fa_stall_min)" '
      def ep(x): (x // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null;
      ((.queue.status // "") as $q | ($q == "queued" or $q == "ready" or $q == "claimed"))
      or .open_pr != null or .parked == true or .verdict == "hold"
      or .verdict == null or .verdict_current != true
      or ((ep(.triaged_at // .updated_at)) as $t | $t != null and (.now - $t) < ($s * 60))' "$1" >/dev/null 2>&1
}

flow_cause() {
  local rec code rc any2=0
  rec=$(mktemp "${TMPDIR:-/tmp}/fa-rec.XXXXXX") || { echo inputs_unreadable; return 0; }
  cat > "$rec"
  for code in $FLOW_CODES; do
    if ! declare -F "flow_rule_$code" >/dev/null 2>&1; then
      # shellcheck source=/dev/null
      . "$_FA_CAUSE_DIR/rules/$code.sh" 2>/dev/null
    fi
    declare -F "flow_rule_$code" >/dev/null 2>&1 || { any2=1; continue; }
    rc=0; "flow_rule_$code" "$rec" || rc=$?
    case "$rc" in
      0) rm -f "$rec"; echo "$code"; return 0 ;;
      2) any2=1 ;;
    esac
  done
  if [ "$any2" = 1 ]; then echo inputs_unreadable
  elif _fa_normal_flow "$rec"; then echo not_stalled
  else echo unknown
  fi
  rm -f "$rec"
  return 0
}

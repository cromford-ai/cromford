#!/bin/bash
# bin/lib/flow-agent/rules/ready_not_queued.sh — flow_rule_ready_not_queued
# <record-file> (BH-9924 slice BH-9956). Sourced by cause.sh.
# MATCH (rc 0) when ALL hold: the verdict is current and is ready or buildable
# (trimmed, lowercased, as console-ui/src/lib/waiting.js norm), there is no
# queue row at all, no live job, no open PR, and the verdict is at least
# flow_agent.stall_min minutes old (fa_stall_min: the row, else
# FLOW_AGENT_STALL_MIN, else 20). rc 1 is no match. rc 2 when the open-PR read
# is unread or truncated and no PR was found, or triaged_at does not parse:
# the answer then depends on an input this pass did not read.
flow_rule_ready_not_queued() {
  local rc
  rc=$(jq -r --argjson s "$(fa_stall_min)" '
      def ep(x): (x // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null;
      ((.verdict // "") | gsub("^\\s+|\\s+$"; "") | ascii_downcase) as $v
      | if .verdict_current != true or ($v != "ready" and $v != "buildable") then 1
        elif .queue != null or .live_job != false then 1
        elif .open_pr != null then 1
        elif ep(.triaged_at) == null then 2
        elif (.now - ep(.triaged_at)) < ($s * 60) then 1
        elif ((.unread // []) | index("pr")) != null or (.pr_truncated // 0) == 1 then 2
        else 0 end' "$1" 2>/dev/null)
  case "$rc" in 0|1|2) return "$rc" ;; *) return 2 ;; esac
}

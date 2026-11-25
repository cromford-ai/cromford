#!/bin/bash
# bin/lib/flow-agent/diagnose.sh — flow_diagnose <record-file>: called once per
# record whose code is unknown. In this slice it writes one log line and makes
# no model call. The diagnosis lands in BH-9924.9 (#9958).
# owner: BH-9924.9 (#9958)
flow_diagnose() {
  local root="${HARNESS:-${H:-}}" p k
  [ -n "$root" ] || return 0
  p=$(jq -r '.project // "-"' "${1:-/dev/null}" 2>/dev/null); k=$(jq -r '.key // "-"' "${1:-/dev/null}" 2>/dev/null)
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s diagnose %s %s not-built\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${p:--}" "${k:--}" >> "$root/logs/flow-agent.log" 2>/dev/null
  return 0
}

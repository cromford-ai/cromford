#!/bin/bash
# bin/lib/fleet-version-rules.d/10-role.sh — sourced by fvc_decide
# (bin/lib/fleet-version-decide.sh), never executed.
# fvc_rule_role reads FVC_ROLE (the registry role of the box):
#   gate-only  SKIP <box> gate-only (registry role), return 2
#   retired    SKIP <box> retired, return 2
#   any other  no output, return 0
# First in name order, so its rc 2 stops the later rules for that box.
FVC_RULES+=(fvc_rule_role)
fvc_rule_role() {
  case "${FVC_ROLE:-}" in
    gate-only) echo "SKIP $FVC_BOX gate-only (registry role)"; return 2 ;;
    retired)   echo "SKIP $FVC_BOX retired"; return 2 ;;
  esac
  return 0
}

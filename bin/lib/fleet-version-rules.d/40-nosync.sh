#!/bin/bash
# bin/lib/fleet-version-rules.d/40-nosync.sh — sourced by fvc_decide
# (bin/lib/fleet-version-decide.sh), never executed.
#
# fvc_rule_nosync — the sync timer rule (BH-7191.2). FVC_SYNC_TIMER is
# box_status.sync_timer as text, which bin/lib/lane-gate.sh reports:
#   0                    ALERT <box> nosync no sync timer
#   1                    nothing
#   empty or any other   OK <box> sync timer not reported
# Empty is a box with no bin/harness-sync-timer.sh, or an older lane-gate, so
# it is not an alert. Returns 0, so the later rules still run.
FVC_RULES+=(fvc_rule_nosync)
fvc_rule_nosync() {
  case "$FVC_SYNC_TIMER" in
    0) echo "ALERT $FVC_BOX nosync no sync timer" ;;
    1) ;;
    *) echo "OK $FVC_BOX sync timer not reported" ;;
  esac
  return 0
}

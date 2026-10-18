#!/bin/bash
# bin/lib/fleet-version-rules.d/20-lag.sh — sourced by fvc_decide
# (bin/lib/fleet-version-decide.sh), never executed.
#
# fvc_rule_lag — the harness version lag rule (BH-7191). In order:
#   no sha                                  ALERT <box> nosha no sha reported
#   no report time, or one older than
#   (60 + FVC_MAX_LAG_MIN) min              ALERT <box> nosha report stale (<iso>)
#   lag notmain                             ALERT <box> lag sha not on main sha=<8>
#   lag >=<n> (older than the fetched log)  ALERT <box> lag lag>=<n>m sha=<8>
#   lag not a whole number                  ALERT <box> lag lag unreadable (<v>) sha=<8>
#   lag > FVC_MAX_LAG_MIN                   ALERT <box> lag lag=<n>m sha=<8>
#   otherwise                               OK <box> lag=<n>m
# The 60 is lane-gate's hourly sha resend (_lg_harness_commit, 3600 s): a box
# that synced correctly still shows its old report for up to an hour.
FVC_RULES+=(fvc_rule_lag)
fvc_rule_lag() {
  local now="${FVC_NOW:-$(date +%s)}" max="${FVC_MAX_LAG_MIN:-30}" s8="${FVC_SHA:0:8}" iso="never" n
  if [ -z "$FVC_SHA" ]; then
    echo "ALERT $FVC_BOX nosha no sha reported"; return 0
  fi
  case "$FVC_REPORTED" in
    ''|*[!0-9]*) echo "ALERT $FVC_BOX nosha report stale ($iso)"; return 0 ;;
  esac
  if [ $(( now - FVC_REPORTED )) -gt $(( (60 + max) * 60 )) ]; then
    iso=$(date -u -d "@$FVC_REPORTED" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || iso="$FVC_REPORTED"
    echo "ALERT $FVC_BOX nosha report stale ($iso)"; return 0
  fi
  case "$FVC_LAG" in
    notmain) echo "ALERT $FVC_BOX lag sha not on main sha=$s8"; return 0 ;;
    '>='[0-9]*) echo "ALERT $FVC_BOX lag lag${FVC_LAG}m sha=$s8"; return 0 ;;
    ''|*[!0-9]*) echo "ALERT $FVC_BOX lag lag unreadable (${FVC_LAG:-empty}) sha=$s8"; return 0 ;;
  esac
  n=$(( 10#$FVC_LAG ))
  if (( n > max )); then
    echo "ALERT $FVC_BOX lag lag=${n}m sha=$s8"
  else
    echo "OK $FVC_BOX lag=${n}m"
  fi
  return 0
}

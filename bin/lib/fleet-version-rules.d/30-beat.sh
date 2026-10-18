#!/bin/bash
# bin/lib/fleet-version-rules.d/30-beat.sh — sourced by fvc_decide
# (bin/lib/fleet-version-decide.sh), never executed.
#
# fvc_rule_beat — the heartbeat rule (BH-7191.2). FVC_BEAT is last_beat_at
# from GET /api/boxes: the box's newest lane tick, ISO. In order:
#   empty, or will not parse                ALERT <box> beat no heartbeat on record
#   older than FVC_MAX_BEAT_GAP_MIN min     ALERT <box> beat no heartbeat <n>m
#   otherwise (a future beat included)      nothing
# <n> is whole minutes, and the test is strict `>`: 30 is quiet, 31 alerts.
# Returns 0, so the later rules still run.
FVC_RULES+=(fvc_rule_beat)
fvc_rule_beat() {
  local now="${FVC_NOW:-$(date +%s)}" max="${FVC_MAX_BEAT_GAP_MIN:-30}" b age
  # Before date -d: `date -d ""` is today's midnight, not an error.
  if [ -z "$FVC_BEAT" ] || ! b=$(date -u -d "$FVC_BEAT" +%s 2>/dev/null); then
    echo "ALERT $FVC_BOX beat no heartbeat on record"; return 0
  fi
  age=$(( (now - b) / 60 ))
  if (( age > max )); then
    echo "ALERT $FVC_BOX beat no heartbeat ${age}m"
  fi
  return 0
}

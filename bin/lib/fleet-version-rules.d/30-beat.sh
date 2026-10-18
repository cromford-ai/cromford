#!/bin/bash
# bin/lib/fleet-version-rules.d/30-beat.sh — sourced by fvc_decide
# (bin/lib/fleet-version-decide.sh), never executed.
# owner BH-7191.2: heartbeat gap over FVC_MAX_BEAT_GAP_MIN -> ALERT <box> beat <detail>.
FVC_RULES+=(fvc_rule_beat)
fvc_rule_beat() { return 0; }

#!/bin/bash
# bin/lib/fleet-version-sink.sh — sourced by bin/fleet-version-check.sh, never
# executed. fvc_sink reads the full fvc_decide output on stdin, after the lane
# wrote its alerts.
# owner BH-7191.4: POST the lag rows for the console.
fvc_sink() { :; }

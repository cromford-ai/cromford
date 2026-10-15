# shellcheck shell=bash
# bin/lib/tailscaled-start.sh — THE command that starts tailscaled on a fleet
# box (BH-6693). Sourced, never run; defining TSD_START is its only effect.
#
# Two callers, one string:
#   bin/box-launch.sh          S4 tailnet: sends it through the Orgo bash API on
#                              a new box (inside `pgrep -x tailscaled || { …; }`).
#   bin/tailscaled-watchdog.sh every 2 minutes on every box: runs it when
#                              `pgrep -x tailscaled` finds nothing (an OOM kill).
# Userspace networking, the state file and the socket are the same on every
# Orgo box. The log is /tmp/tailscaled.log, as box-launch.sh always wrote it.
# shellcheck disable=SC2034  # read by the scripts that source this file
TSD_START='setsid -f /usr/sbin/tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock >/tmp/tailscaled.log 2>&1'

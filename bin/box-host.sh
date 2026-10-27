#!/bin/bash
# box-host.sh <box> — the ssh host for a fleet box (BH-8545).
#
# WHY: a hub->box push that ssh's `root@<box name>` trusts tailnet DNS, and a
# tailnet name can point at a dead device. On 2026-10-24 box-project-1-1
# resolved to a device offline for 58 days, and every Vercel snapshot push to
# that box timed out. The registry's own answer for "where is this box" is
# fleet.conf column 7 (the tailnet IP), read through bin/fleet-conf.sh
# --tailnet-ip-of-box. bin/box-for.sh is NOT changed: its answer is a box
# IDENTITY for 30+ callers, not an ssh host.
#
# CONTRACT:
#   <box> with an IP in fleet.conf (a row, or a `# @box` directive) -> the IP
#   <box> with no IP (no column 7, `-`, unknown box)  -> the box name (the
#       fallback: exactly what the caller ssh'd before, so no push that works
#       today stops)
#   `local`                                           -> `local`
#   no or empty argument -> usage on stderr, rc 2, nothing on stdout
# Every answer is rc 0 and one line, so `root@$(box-host.sh "$b")` is never
# `root@`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOX="${1:-}"
[ -n "$BOX" ] || { echo "usage: box-host.sh <box>" >&2; exit 2; }
[ "$BOX" = local ] && { echo local; exit 0; }
IP=$("$HERE/fleet-conf.sh" --tailnet-ip-of-box "$BOX" 2>/dev/null) || IP=""
if [ -n "$IP" ] && [ "$IP" != "-" ]; then echo "$IP"; exit 0; fi
echo "$BOX"

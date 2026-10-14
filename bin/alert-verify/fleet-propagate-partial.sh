#!/bin/bash
# bin/alert-verify/fleet-propagate-partial.sh — the verify script of the `fleet-propagate-partial` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# bin/fleet-propagate.sh's `propagating <sha7> to the fleet FAILED in part` page.
# Reads ONLY the last 20 KB of logs/fleet-propagate.log. Cleared when the LAST
# run line there for that sha (`<old>..<sha7> hub=… boxes=K/K …`) is clean:
# hub=ok, K/K boxes with K > 0, no failed= and no failed crontab. That run came
# after the partial one or is the only one left in the window. A partial last
# line, or no line for the sha at all, still reproduces. No log is doubt.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
M=$(av_field line | av_one '\[orchestrator/fleet-propagate\] propagating [0-9a-f]{7,} to the fleet FAILED in part') || exit 75
read -r _ _ SHA _ <<<"$M"
SHA=${SHA:0:7}
LOG="$AV_HARNESS/logs/fleet-propagate.log"
[ -r "$LOG" ] || exit 75
LAST=$(tail -c 20000 "$LOG" | { grep -F -- "..$SHA " || true; } | tail -n 1) || exit 75
[[ "$LAST" =~ \ hub=ok\ boxes=([0-9]+)/([0-9]+)\  ]] || exit 1
[ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[1]}" -gt 0 ] || exit 1
grep -qE ' failed=| cron=(render-failed|install-failed|refused-)' <<<"$LAST" && exit 1
echo "fleet-propagate-partial: ${LAST}"

#!/bin/bash
# bin/cmd-pool-cap.sh <project> <payload-json> <command_id> — the console's
# pool_cap command (BH-6737). Runs on the hub from bin/poll-commands.sh.
#
# payload {cap: <integer 0..999>}. The cap is ONE settings row,
# lane.fly-pool.<project lowercased>.pool_cap (knob POOL_CAP; the key comes from
# bin/pool-cap.sh --knob-key), written through bin/jobs-client.sh setting-set.
# cap = 0 is the row value 0: no per-project ceiling. This command writes NO
# flags/ file (PR #7045, the operator 2026-10-16: the settings row API, not a flag-file
# write). flags/fly-pool-<p> stays the pool's enable switch and is only READ: a
# pool that is not enabled (no flag file) is refused and nothing is written.
# The cap is refused, never clamped, when it is not a JSON integer in range (D11).
#
# Prints ONE JSON line: {result, project, cap_set, pool_cap, reason}. pool_cap
# is what bin/pool-cap.sh <p> prints AFTER the write, so a number inside the
# flag file, POOL_CAP_MAX or POOL_AUTOSCALE=0 reports that number and the
# reason names the source that wins.
# Exit 0 ok, 3 refused, 1 failed (retryable).
set -uo pipefail
H="${HARNESS:-/root/harness}"
PROJECT="${1:-}"; PAYLOAD="${2:-}"

# emit <rc> <result> <reason> [cap_set] [pool_cap] — print the line, exit rc.
emit() {
  jq -nc --arg r "$2" --arg p "$PROJECT" --arg why "${3:0:200}" --arg cs "${4:-}" --arg pc "${5:-}" \
    '{result:$r, project:$p}
     + (if $cs == "" then {} else {cap_set:($cs|tonumber)} end)
     + (if $pc == "" then {} else {pool_cap:($pc|tonumber)} end)
     + {reason:$why}'
  exit "$1"
}

[[ "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$PROJECT" != *..* ]] || emit 3 refused "bad project"
"$H/bin/fleet-conf.sh" --projects 2>/dev/null | grep -qxF -- "$PROJECT" \
  || emit 3 refused "$PROJECT is not a fleet.conf project"
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$PAYLOAD" || emit 3 refused "payload is not a JSON object"
CAP=$(jq -r 'if (.cap|type) == "number" and .cap == (.cap|floor) and .cap >= 0 and .cap <= 999
             then (.cap|floor|tostring) else "" end' <<<"$PAYLOAD" 2>/dev/null)
[[ "$CAP" =~ ^(0|[1-9][0-9]{0,2})$ ]] || emit 3 refused "cap must be a JSON integer from 0 to 999"

# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || flag_file_on() { [ -f "$H/flags/$1-$2" ]; }
flag_file_on fly-pool "$PROJECT" \
  || emit 3 refused "no flags/fly-pool-$PROJECT: the pool is not enabled; nothing written"

KEY=$("$H/bin/pool-cap.sh" --knob-key "$PROJECT" 2>/dev/null) \
  || emit 3 refused "no legal settings key for project $PROJECT; nothing written"
CMD_ID="${3:-}"
timeout 15 "$H/bin/jobs-client.sh" setting-set "$KEY" "$CAP" "console pool_cap command $CMD_ID" >/dev/null 2>&1 \
  || emit 1 failed "settings write failed for $KEY; nothing written"

NOW=$("$H/bin/pool-cap.sh" "$PROJECT" 2>/dev/null)
[[ "$NOW" =~ ^[0-9]+$ ]] || emit 1 failed "row $KEY written, but pool-cap.sh $PROJECT did not answer a number" "$CAP"
FN=$(tr -dc '0-9' < "$H/flags/fly-pool-$PROJECT" 2>/dev/null)
AS=$("$H/bin/pool-cap.sh" --autoscale 2>/dev/null)
if [ "$NOW" = "$CAP" ]; then
  WHY="settings row $KEY = $CAP; pool-cap.sh reads $CAP"
elif [ "$AS" = 0 ]; then
  WHY="settings row $KEY = $CAP, but POOL_AUTOSCALE=0 ignores the row; pool-cap.sh reads $NOW"
elif [ -n "$FN" ]; then
  WHY="settings row $KEY = $CAP, but flags/fly-pool-$PROJECT holds $FN, which wins over the row; pool-cap.sh reads $NOW"
else
  WHY="settings row $KEY = $CAP, but POOL_CAP_MAX trims it to $NOW"
fi
emit 0 ok "$WHY" "$CAP" "$NOW"

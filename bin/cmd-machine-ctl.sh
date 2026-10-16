#!/bin/bash
# bin/cmd-machine-ctl.sh <project> <payload-json> <command_id> — the console's
# machine_ctl command (BH-6737). Runs on the hub from bin/poll-commands.sh.
#
# payload {machine_id, op: start|stop|destroy}. It runs
# bin/fly-api.sh <project> <op> <machine_id> under `timeout 150` and reports
# the state fly-api.sh printed after the op (its last stdout line), never the
# op that was asked for.
#
# DESTROY GUARD, before any Fly call: a pool job record in state/fly-pool/<p>/
# that names the machine (file <id>.json, or .machine = id) is a live build
# claim, and the destroy is refused. A record that cannot be read refuses too
# (fail closed). This is the rule box_ops_fly_destroy (bin/lib/box-ops-fly.sh)
# applies. bin/fly-api.sh itself refuses the builder machine (rc 2).
#
# Prints ONE JSON line: {result, project, machine_id, op, state, reason}.
# Exit 0 ok, 3 refused, 1 failed (retryable).
set -uo pipefail
H="${HARNESS:-/root/harness}"
PROJECT="${1:-}"; PAYLOAD="${2:-}"
MID=""; OP=""

emit() { # emit <rc> <result> <reason> [state]
  jq -nc --arg r "$2" --arg p "$PROJECT" --arg m "$MID" --arg o "$OP" --arg s "${4:-}" --arg why "${3:0:200}" \
    '{result:$r, project:$p, machine_id:$m, op:$o} + (if $s == "" then {} else {state:$s} end) + {reason:$why}'
  exit "$1"
}

[[ "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$PROJECT" != *..* ]] || emit 3 refused "bad project"
"$H/bin/fleet-conf.sh" --projects 2>/dev/null | grep -qxF -- "$PROJECT" \
  || emit 3 refused "$PROJECT is not a fleet.conf project"
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$PAYLOAD" || emit 3 refused "payload is not a JSON object"
MID=$(jq -r 'if (.machine_id|type) == "string" then .machine_id else "" end' <<<"$PAYLOAD")
OP=$(jq -r 'if (.op|type) == "string" then .op else "" end' <<<"$PAYLOAD")
[[ "$MID" =~ ^[0-9a-z]{8,32}$ ]] || { MID=""; emit 3 refused "machine_id must match [0-9a-z]{8,32}"; }
case "$OP" in start|stop|destroy) ;; *) OP=""; emit 3 refused "op must be start, stop or destroy" ;; esac

if [ "$OP" = destroy ]; then
  for f in "$H/state/fly-pool/$PROJECT"/*.json; do
    case "${f##*/}" in .*) continue ;; esac
    [ -f "$f" ] || continue
    m=$(jq -r '.machine // ""' "$f" 2>/dev/null) || emit 3 refused "cannot read pool record ${f##*/}; not destroyed"
    if [ "${f##*/}" = "$MID.json" ] || [ "$m" = "$MID" ]; then
      emit 3 refused "live pool job ${f##*/} names $MID; not destroyed"
    fi
  done
fi

ERRF=$(mktemp "${TMPDIR:-/tmp}/cmd-machine-ctl.XXXXXX") || emit 1 failed "no temp file"
OUT=$(timeout 150 "$H/bin/fly-api.sh" "$PROJECT" "$OP" "$MID" 2>"$ERRF"); RC=$?
ERR=$(head -n 1 "$ERRF" | tr -d '\r'); rm -f "$ERRF"
STATE=$(printf '%s\n' "$OUT" | grep . | tail -n 1)
case "$RC" in
  0)   emit 0 ok "fly-api.sh $OP answered $STATE" "$STATE" ;;
  2)   emit 3 refused "fly-api.sh refused: ${ERR:-rc 2}" "$STATE" ;;
  124) emit 1 failed "fly-api.sh $OP timed out after 150s" "$STATE" ;;
  *)   emit 1 failed "fly-api.sh $OP rc $RC${ERR:+: $ERR}" "$STATE" ;;
esac

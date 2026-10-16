#!/bin/bash
# bin/fly-api.sh <project> start|stop|state|destroy [<machine-id>] — thin curl
# wrapper over the Fly Machines API (Phase 1 of the Fly builder trial). Runs on
# the HUB.
#
# Used by hand in Phase-1 verify and (Phase 2) by the dispatcher. Uses the
# per-app deploy token FLY_API_TOKEN_<PROJECT> from /root/harness/env/fly.env —
# a leaked token can start/stop ONE builder, not touch the others.
#
# API (per plan "Fly specifics", base <ENDPOINT_FLY_MACHINES>/v1, Bearer=token):
#   state : GET  /apps/{app}/machines/{id}   -> prints .state (started|stopped|...)
#   start : POST /apps/{app}/machines/{id}/start
#   stop  : POST /apps/{app}/machines/{id}/stop
#   destroy: DELETE /apps/{app}/machines/{id}?force=true -> prints destroyed
#           (200) or already gone (404), exit 0; any other code prints
#           failed http=<code>, exit 1. One call, no wait. It refuses (exit 2,
#           before any call) the builder machine: the builder app re-creates a
#           machine it loses (SPRAWL GUARD), so only a pool machine is destroyed.
#
# <machine-id> (BH-6737, the console's machine_ctl command): with no id, every
# action reads the builder machine of state/fly/<project>.json exactly as
# before. An id must match ^[0-9a-z]{8,32}$. The builder's own id keeps the
# builder app; any other id is a pool machine in flags/fly-pool-app-<project>.
#
# Open-detail decisions (simplest robust option, per task brief):
#   - Machine id + app come from state/fly/<project>.json (written by
#     fly-provision.sh) — single source of truth, no second place to keep in sync.
#   - `start` and `stop` block briefly polling the resulting state so callers get
#     a definitive started/stopped rather than an async ack; a 90s ceiling
#     matches the plan's "within 90s tailscale ping OK" verify budget.
#   - Exit code encodes the outcome: 0 = requested state reached (or already
#     there); nonzero = API error or timeout, so the dispatcher can branch on it.
set -uo pipefail

PROJECT="${1:?usage: fly-api.sh <project> start|stop|state|destroy [<machine-id>]}"
ACTION="${2:?usage: fly-api.sh <project> start|stop|state|destroy [<machine-id>]}"
REQ_MID="${3:-}"

HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
FLYENV="$HENV/fly.env"
STATE_FILE="$HARNESS/state/fly/$PROJECT.json"

die() { echo "fly-api/$PROJECT FATAL: $*" >&2; exit 1; }
# The base URL is the endpoint-fly-machines knob (BH-1941): the env, else the
# registry default. Resolved before any call; an unresolvable endpoint is fatal.
. "${HARNESS:-/root/harness}/bin/lib/endpoints.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/endpoints.sh" 2>/dev/null
BASE=$(endpoint_url fly-machines 2>/dev/null) || die "no Fly Machines endpoint (ENDPOINT_FLY_MACHINES: no env, no registry default)"
API="$BASE/v1"
command -v jq >/dev/null 2>&1 || die "jq required"
[ -f "$FLYENV" ] || die "$FLYENV missing"
if [ -n "$REQ_MID" ]; then
  [[ "$REQ_MID" =~ ^[0-9a-z]{8,32}$ ]] || die "bad machine id '$REQ_MID' (want [0-9a-z]{8,32})"
else
  [ -f "$STATE_FILE" ] || die "$STATE_FILE missing (run fly-provision.sh $PROJECT first)"
fi

set -a; . "$FLYENV"; set +a
PU=$(echo "$PROJECT" | tr '[:lower:].-' '[:upper:]__')
TOK_VAR="FLY_API_TOKEN_$PU"
TOKEN="${!TOK_VAR:-}"
[ -n "$TOKEN" ] || die "$TOK_VAR unset in $FLYENV (provision creates it)"

APP=""; MID=""
if [ -f "$STATE_FILE" ]; then
  APP=$(jq -r '.app // ""' "$STATE_FILE")
  MID=$(jq -r '.machine_id // ""' "$STATE_FILE")
fi
BUILDER_MID="$MID"
if [ -n "$REQ_MID" ] && [ "$REQ_MID" != "$BUILDER_MID" ]; then
  APP=$(tr -d '[:space:]' < "$HARNESS/flags/fly-pool-app-$PROJECT" 2>/dev/null)
  [[ "$APP" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "no pool app for $PROJECT (flags/fly-pool-app-$PROJECT)"
  MID="$REQ_MID"
fi
[ -n "$APP" ] && [ -n "$MID" ] || die "app/machine_id missing in $STATE_FILE"

api() { # api <method> <path>
  curl -s --max-time 30 -X "$1" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    "$API/apps/$APP/machines/$MID$2"
}

get_state() { api GET "" | jq -r '.state // "unknown"'; }

wait_for() { # wait_for <desired-state> <seconds>
  local want="$1" budget="${2:-90}" waited=0 st
  while [ "$waited" -lt "$budget" ]; do
    st=$(get_state)
    [ "$st" = "$want" ] && { echo "$st"; return 0; }
    sleep 3; waited=$((waited + 3))
  done
  echo "$(get_state)"; return 1
}

case "$ACTION" in
  state)
    get_state
    ;;
  start)
    st=$(get_state)
    if [ "$st" = "started" ]; then echo "started"; exit 0; fi
    api POST "/start" >/dev/null
    final=$(wait_for started 90); rc=$?
    echo "$final"
    exit $rc
    ;;
  stop)
    st=$(get_state)
    if [ "$st" = "stopped" ]; then echo "stopped"; exit 0; fi
    api POST "/stop" >/dev/null
    final=$(wait_for stopped 90); rc=$?
    echo "$final"
    exit $rc
    ;;
  destroy)
    if [ -n "$BUILDER_MID" ] && [ "$MID" = "$BUILDER_MID" ]; then
      echo "fly-api/$PROJECT REFUSED: $MID is the builder machine; destroy only takes a pool machine" >&2
      exit 2
    fi
    code=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer $TOKEN" \
      "$API/apps/$APP/machines/$MID?force=true")
    case "$code" in
      200) echo "destroyed"; exit 0 ;;
      404) echo "already gone"; exit 0 ;;
      *)   echo "failed http=${code:-000}"; exit 1 ;;
    esac
    ;;
  *)
    die "unknown action '$ACTION' (start|stop|state|destroy)"
    ;;
esac

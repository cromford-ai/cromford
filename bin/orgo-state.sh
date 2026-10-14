#!/bin/bash
# bin/orgo-state.sh — hub cron (*/5): copy each Orgo account's computer list
# into the jobs worker, for the /machines ORGO STATE column (BH-5750, C4).
#
# WHY. /machines showed only the watchdog ping age for an Orgo box. Nothing
# stored what Orgo itself says: running or stopped, and the specs. This lane
# keeps a local copy (data independence): orgo_computers in D1, written
# through PUT /api/orgo-computers (worker/jobs/src/routes/orgo-computers.js).
#
# RUN ORDER
#   gate      lane_gate_or_exit orgo-state (flags/all-off, flags/lane-off-orgo-state).
#   hub       bin/hub-lease.sh check must pass (the cron line checks it too);
#             not the hub = exit 0, nothing read.
#   lock      flock -n locks/orgo-state.lock; held = a tick is running, exit 0.
#             Dedupe only, never a wait.
#   knob      ORGO_STATE_CALL_TIMEOUT_S must be a positive integer; anything
#             else is one ALERTS line and exit 1, nothing read (never clamped).
#   accounts  each key of catalog/orgo-plans.json .accounts (the Orgo accounts;
#             .cost_account names its catalog/cost-accounts.json entry). Its
#             key_env names the env var with the API key.
#   per account:
#     no key      "not configured": one log line, no Orgo call, no PUT, no ALERT.
#     GET /computers through orgo() (bin/lib/restore-drill-orgo.sh), curl -m
#                 ORGO_STATE_CALL_TIMEOUT_S. The list is an array or
#                 {computers:[…]} (the shape bin/box-launch.sh reads).
#     failed read a non-2xx or an unreadable body: PUT {ok:false,
#                 complete:false, computers:[]}. The worker changes no computer
#                 row for it and records the failed read; no ALERT (the console
#                 shows the read as failed and stale).
#     list        PUT {ok:true, complete:true, computers}. Over 500 entries (the
#                 route's bound): the first 500 with complete:false and the real
#                 count in detail, so nothing is tombstoned on a capped read.
#     Each entry is sent as Orgo gave it, minus top-level keys that look like a
#     secret (pass, token, secret, key, auth, cred). The API key itself rides
#     orgo()'s header file and is never logged or sent to the worker.
#   log       one logs/orgo-state.log line per account, then
#             `checked=N ok=N failed=N not_configured=N unsent=N`.
# Exit: 0 done / gated / not the hub / locked, 1 a bad knob or no catalog.
#
# Knobs (catalog/lanes.d/orgo-state.json): ORGO_STATE_CALL_TIMEOUT_S (30).
# ORGO_API_BASE is the orgo() seam's base URL.
# Run by hand: bin/orgo-state.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s/env\n' "${1:-$H}"; }
HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. Both fail OPEN. Registry: catalog/lanes.json. Operator:
# bin/harness-ctl.sh off orgo-state.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit orgo-state
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    orgo-state
set -a
# shellcheck disable=SC1091
. "$HENV/global.env" 2>/dev/null
set +a
# Again below the env load: the settings row must win over global.env.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    orgo-state

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
# shellcheck source=bin/lib/restore-drill-orgo.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/restore-drill-orgo.sh" || exit 1

LOG="$H/logs/orgo-state.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s [orgo-state] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$LOG"; }
alert() { HARNESS="$H" "$H/bin/alert-line.sh" "[orgo-state] $*"; }

"$H/bin/hub-lease.sh" check >/dev/null 2>&1 || exit 0

exec 9>"$H/locks/orgo-state.lock"
flock -n 9 || exit 0

TO="${ORGO_STATE_CALL_TIMEOUT_S:-30}"
[[ "$TO" =~ ^[1-9][0-9]*$ ]] \
  || { alert "orgo-state: ORGO_STATE_CALL_TIMEOUT_S '$TO' is not a positive integer; no Orgo account read"; exit 1; }
MAX=500   # the bound PUT /api/orgo-computers takes (MAX_COMPUTERS in the route)

PLANS="$H/catalog/orgo-plans.json"
ACCTS=$(jq -r '.accounts | keys[]' "$PLANS" 2>/dev/null) \
  || { alert "orgo-state: $PLANS is missing or has no .accounts; no Orgo account read"; exit 1; }

N=0 NOK=0 NFAIL=0 NNC=0 NUNSENT=0
put() { # put <account> <json-body> <what>: PUT the read, log the outcome
  local rc
  _jobs_req PUT /api/orgo-computers "$2" >/dev/null; rc=$?
  if [ "$rc" = 0 ]; then log "account $1: $3; sent"
  elif [ "$rc" = 2 ]; then NUNSENT=$((NUNSENT+1)); log "account $1: $3; not sent: PUT /api/orgo-computers HTTP 404 (route not deployed)"
  else NUNSENT=$((NUNSENT+1)); log "account $1: $3; not sent: PUT /api/orgo-computers HTTP ${JOBS_HTTP:-none}"
  fi
}
failed() { # failed <account> <detail>
  NFAIL=$((NFAIL+1))
  put "$1" "$(jq -nc --arg a "$1" --arg d "$2" '{account:$a, ok:false, complete:false, computers:[], detail:$d}')" "read failed ($2)"
}

while IFS= read -r A; do
  [ -n "$A" ] || continue
  N=$((N+1))
  if ! [[ "$A" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    NFAIL=$((NFAIL+1)); log "account '${A:0:64}': name does not match [A-Za-z0-9._-]{1,64}; skipped"; continue
  fi
  KEYENV=$(jq -r --arg a "$A" '.accounts[$a].key_env // "ORGO_API_KEY"' "$PLANS")
  if ! [[ "$KEYENV" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    NFAIL=$((NFAIL+1)); log "account $A: key_env '${KEYENV:0:64}' is not an env var name; skipped"; continue
  fi
  KEY="${!KEYENV:-}"
  if [ -z "$KEY" ]; then
    NNC=$((NNC+1)); log "account $A: not configured ($KEYENV is unset); nothing read or sent"; continue
  fi
  ORGO_API_KEY="$KEY" RESTORE_DRILL_CALL_TIMEOUT_S="$TO" orgo GET /computers
  RRC=$?
  if [ "$RRC" != 0 ]; then failed "$A" "GET /computers HTTP $ORGO_HTTP"; continue; fi
  if ! LIST=$(printf '%s' "$ORGO_BODY" | jq -ce '
      (if type == "array" then . elif (.computers | type) == "array" then .computers else error("shape") end)
      | map(if type == "object" then with_entries(select(.key | test("pass|token|secret|key|auth|cred"; "i") | not)) else . end)' 2>/dev/null); then
    failed "$A" "unreadable computer list from GET /computers"; continue
  fi
  COUNT=$(jq length <<<"$LIST")
  if [ "$COUNT" -gt "$MAX" ]; then
    BODY=$(jq -c --arg a "$A" --argjson m "$MAX" --arg d "list capped at $MAX of $COUNT computers" \
      '{account:$a, ok:true, complete:false, computers:.[:$m], detail:$d}' <<<"$LIST")
    WHAT="$COUNT computers, capped at $MAX (complete:false)"
  else
    BODY=$(jq -c --arg a "$A" '{account:$a, ok:true, complete:true, computers:.}' <<<"$LIST")
    WHAT="$COUNT computers (complete)"
  fi
  NOK=$((NOK+1))
  put "$A" "$BODY" "$WHAT"
done <<<"$ACCTS"

log "checked=$N ok=$NOK failed=$NFAIL not_configured=$NNC unsent=$NUNSENT"
exit 0

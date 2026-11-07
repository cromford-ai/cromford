#!/bin/bash
# bin/archie-replay-model.sh — BH-4066 (BH-3966.5): the live model behind
# Archie's replay gate. bin/archie-learn.sh hands it to bin/archie-skill-replay.sh
# as ARCHIE_REPLAY_MODEL_CMD, so a skill edit is judged by a model that reads
# the NEW SKILL.md (the recorded replayer replays recorded.txt and cannot tell
# a good edit from a bad one).
#
# usage: archie-replay-model.sh <prompt-file> <case-dir>   (the runner's contract)
# stdout: the reply. rc 0 = answered (a blank answer is rc 0 with no stdout,
# which the runner reads as got=none); rc 75 = no call was made (no route, or
# ARCHIE_REPLAY_MAX_USD=0); rc 1 = failed, or the attempt cap is reached.
#
# Spend, in this order (dedup before spend):
#   1. model = model_routes stage.archie-replay (lane_role_model). No route = rc
#      75, no call. No model literal lives here.
#   2. the ledger state/archie-learn/replay-cache/<sha256(model + prompt)>.json
#      {outcome, attempts, reply, ts}: `ok` prints the stored reply, `empty`
#      prints nothing, both with no call; `failed` at ARCHIE_REPLAY_MAX_ATTEMPTS
#      (default 2) is rc 1 with no call.
#   3. the attempt is written (failed, attempts+1) BEFORE the call; a failed
#      write is no call.
#   4. ONE agent-call: stage archie-replay, lane archie-learn, capped by
#      AGENT_CALL_BUDGET_USD_ARCHIE_REPLAY=ARCHIE_REPLAY_MAX_USD (default 0.05).
#      rc 74-79 billed nothing, so the attempt is handed back. Another failure
#      stays counted. A non-blank reply is `ok`, a blank one `empty`.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
PF="${1:-}"
[ -r "$PF" ] || { echo "usage: archie-replay-model.sh <prompt-file> <case-dir>" >&2; exit 2; }
# shellcheck disable=SC1091
{
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_LEARN_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_LEARN_FIXTURE"
fi
command -v jq >/dev/null 2>&1 || { echo "archie-replay-model: jq is required" >&2; exit 1; }
command -v lane_role_model >/dev/null 2>&1 || { echo "archie-replay-model: bin/lib/lane-model.sh missing" >&2; exit 75; }

LOG="$H/logs/archie-learning.log"
log() { mkdir -p "$H/logs" 2>/dev/null; printf '%s replay-model %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

MAXA="${ARCHIE_REPLAY_MAX_ATTEMPTS:-2}"
if ! [[ $MAXA =~ ^[0-9]+$ ]] || [ "$((10#$MAXA))" -lt 1 ] || [ "$((10#$MAXA))" -gt 10 ]; then
  log "warn: ARCHIE_REPLAY_MAX_ATTEMPTS=$MAXA is outside 1..10; using the default 2"; MAXA=2
fi
MAXA=$((10#$MAXA))
USD="${ARCHIE_REPLAY_MAX_USD:-0.05}"
if ! [[ $USD =~ ^[0-9]+(\.[0-9]+)?$ ]]; then log "warn: ARCHIE_REPLAY_MAX_USD=$USD is not a number; using the default 0.05"; USD=0.05; fi
awk -v u="$USD" 'BEGIN { exit !(u + 0 > 0) }' || { echo "archie-replay-model: ARCHIE_REPLAY_MAX_USD=0, replays are off" >&2; exit 75; }

if ! MODEL=$(lane_role_model stage.archie-replay) || [ -z "$MODEL" ]; then
  echo "archie-replay-model: no model route for stage.archie-replay; nothing called" >&2
  exit 75
fi
SHA=$( { printf '%s\n' "$MODEL"; cat "$PF"; } | sha256sum | cut -c1-64)
DIRC="$H/state/archie-learn/replay-cache"
LED="$DIRC/$SHA.json"
mkdir -p "$DIRC" 2>/dev/null

OUTCOME=""; ATT=0
# >>> ledger read
if [ -f "$LED" ]; then
  OUTCOME=$(jq -r '.outcome // ""' "$LED" 2>/dev/null)
  ATT=$(jq -r '.attempts // 0' "$LED" 2>/dev/null)
  [[ $ATT =~ ^[0-9]+$ ]] || ATT=0
  case "$OUTCOME" in
    ok) jq -r '.reply' "$LED"; exit 0 ;;
    empty) exit 0 ;;
    failed) [ "$ATT" -ge "$MAXA" ] && { echo "archie-replay-model: this prompt failed $ATT times; not calling again" >&2; exit 1; } ;;
  esac
fi
# <<< ledger read

# write_led <outcome> <attempts> [reply]: temp + mv, rc of the write.
write_led() {
  jq -n --arg o "$1" --argjson a "$2" --arg r "${3:-}" --arg t "$(date -u +%FT%TZ)" \
    '{outcome: $o, attempts: $a, reply: $r, ts: $t}' > "$LED.tmp" 2>/dev/null && mv -f "$LED.tmp" "$LED"
}

ATT=$((ATT + 1))
write_led failed "$ATT" || { echo "archie-replay-model: the attempt could not be recorded; nothing called" >&2; exit 1; }
RAW=$(mktemp "${TMPDIR:-/tmp}/archie-replay.XXXXXX") || exit 1
# Archie runs this from inside an orchestrator turn, whose env names that turn's
# own guard family and ticket; this call is its own work, so those are reset.
env -u AGENT_CALL_TICKET -u AGENT_CALL_PR -u AGENT_CALL_GUARD_FORCE \
  AGENT_CALL_NO_TOOLS=1 AGENT_CALL_LANE=archie-learn AGENT_CALL_FP="archie-replay:$SHA" AGENT_CALL_GUARD_STAGE=archie-replay \
  AGENT_CALL_BUDGET_USD_ARCHIE_REPLAY="$USD" "$H/bin/agent-call.sh" archie-replay fleet "$MODEL" 180 "$RAW" "@$PF" >/dev/null 2>&1
RC=$?
TEXT=$(cat "$RAW" 2>/dev/null); rm -f "$RAW"
if [ "$RC" != 0 ]; then
  if [ "$RC" -ge 74 ] && [ "$RC" -le 79 ]; then
    # Nothing was billed, so the attempt is handed back.
    write_led failed "$((ATT - 1))" || true
    log "agent-call refused (rc=$RC, nothing billed) for $SHA"
  else
    log "agent-call failed (rc=$RC) for $SHA, attempt $ATT of $MAXA"
  fi
  exit 1
fi
if [ -z "${TEXT//[[:space:]]/}" ]; then
  write_led empty "$ATT" || true
  exit 0
fi
write_led ok "$ATT" "$TEXT" || log "warn: the reply for $SHA was paid for and not recorded"
printf '%s\n' "$TEXT"
exit 0

# BH-7968 owns this file
# shellcheck shell=bash
# bin/lib/onboard-envelopes.sh — the onboarding runner's envelope step,
# sourced by bin/onboard-run.sh, never run. Doc: docs/SECRETS-ENVELOPE.md.
#
# obe_consume <run-json-file> <run-id>
#   The run json is the GET /api/onboarding/runs/<id> answer. When the run has
#   a queued step and an ai_envelope input (the AI-account envelope the
#   onboarding form sealed, BH-7968), run the consumer once with that id. The
#   read deletes the envelope, so secrets-apply never applies it a second
#   time; a consume that already happened answers 404 (exit 3), logged `gone`.
#   The envelope's scope names the run's project, and envelope-consume.sh
#   refuses an unregistered project only AFTER the read deleted it. So while
#   bin/fleet-conf.sh --projects does not list the run's project, the call
#   does not consume: it logs `held` and the envelope stays pending
#   (secrets-apply holds it too). bin/onboard-run.sh calls it before the
#   stations and again after the register station; the consumer runs at most
#   once per process (OBE_CALLED).
#   One log line per call, through the caller's `line` when it has one, else
#   stdout:
#     envelope <run> <id> applied | gone | deferred rc=75 | failed rc=<n>
#     envelope <run> <id> held (project <p> not registered)
#     envelope <run> refused bad id
#   Returns 0 on every path: a consume result never fails or stops the run,
#   because the account row carries its own result.
#
# Env, test seams: ONBOARD_ENVELOPE_CONSUME (the consumer, default
# bin/envelope-consume.sh next to this lib's bin/); ONBOARD_FLEET_CONF (the
# registry reader, default bin/fleet-conf.sh next to this lib's bin/).

OBE_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
OBE_CALLED=0

_obe_log() {
  if declare -F line >/dev/null 2>&1; then line "$1"; else printf '%s\n' "$1"; fi
}

obe_consume() {
  local f="${1:-}" run="${2:-}" env rc consumer bin proj
  [ "$OBE_CALLED" = 0 ] || return 0
  [ -r "$f" ] || return 0
  jq -e '[.steps[]? | select(.state == "queued")] | length > 0' "$f" >/dev/null 2>&1 || return 0
  env=$(jq -r '.run.inputs.ai_envelope // empty | strings' "$f" 2>/dev/null)
  [ -n "$env" ] || return 0
  if ! [[ "$env" =~ $OBE_UUID_RE ]]; then
    _obe_log "envelope $run refused bad id"
    return 0
  fi
  bin="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
  proj=$(jq -r '.run.inputs.project // empty | strings' "$f" 2>/dev/null)
  # REGISTRY_CACHE_TTL_S=0: a db-mode cache filled before register lacks the row.
  if [ -z "$proj" ] || ! REGISTRY_CACHE_TTL_S=0 "${ONBOARD_FLEET_CONF:-$bin/fleet-conf.sh}" --projects 2>/dev/null | grep -qxF -- "$proj"; then
    _obe_log "envelope $run $env held (project ${proj:--} not registered)"
    return 0
  fi
  consumer="${ONBOARD_ENVELOPE_CONSUME:-$bin/envelope-consume.sh}"
  OBE_CALLED=1
  "$consumer" "$env" < /dev/null > /dev/null 2>&1; rc=$?
  case "$rc" in
    0) _obe_log "envelope $run $env applied" ;;
    3) _obe_log "envelope $run $env gone" ;;
    75) _obe_log "envelope $run $env deferred rc=75" ;;
    *) _obe_log "envelope $run $env failed rc=$rc" ;;
  esac
  return 0
}

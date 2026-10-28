#!/bin/bash
# bin/secrets-apply.sh — BH-7965 (BH-7937.2): the hub's per-minute secret
# envelope lane (cron/lanes/773-secrets-apply.cron). No LLM call.
#
# One tick: GET /api/secrets/envelope?state=pending&limit=$SECRETS_APPLY_BATCH
# (main bearer AND x-envelope-hub-token), then bin/envelope-consume.sh <id> once
# per pending id whose scope starts `ai-account:` or `fleet:` (BH-8541), one
# after the other (two envelopes for one env file never race). Other scopes
# (tracker:) stay for their own consumer. An ai-account project scope whose
# project bin/fleet-conf.sh --projects does not list stays pending too, one
# `held <id> (project <p> not registered)` line (BH-7968).
# `flock -n locks/secrets-apply.lock` dedupes: a held lock
# skips the tick. Rotated keys envelope.key.<epoch> older than the TTL are
# deleted first. Doc: docs/SECRETS-ENVELOPE.md.
#
# Exit 0 after every tick, and when ENVELOPE_HUB_TOKEN is not set (one log
# line: the lane is inert until an operator sets it). Exit 1 on a knob out of
# range (one ALERTS line, no request).
# Log line (logs/secrets-apply.log):
#   <ts> tick pending=<n> consumed=<n> failed=<n> skipped=<n> truncated=<true|false>
# Env: ENVELOPE_KEY, ENVELOPE_NOW (epoch seconds; test seam).
# OFF: flags/lane-off-secrets-apply. Registry: catalog/lanes.d/secrets-apply.json.
set -uo pipefail
set +x
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit secrets-apply
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply secrets-apply

mkdir -p "$H/logs" "$H/locks" "$H/state" 2>/dev/null
LOG="$H/logs/secrets-apply.log"
line() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG"; }
alert() { "$SELF/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

# Knobs: catalog/lanes.d/secrets-apply.json, rows lane.secrets-apply.<knob>.
# An out-of-range value is refused, never clamped.
knob() { # knob <name> <value> <min> <max>
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] && return 0
  alert --id "secrets-apply:knob:$1" --severity warn secrets-apply "$1=$2 is not in $3..$4; secrets-apply did not run."
  line "refused: $1 not in $3..$4"
  exit 1
}
BATCH="${SECRETS_APPLY_BATCH:-20}"                   # lane.secrets-apply.secrets_apply_batch
knob SECRETS_APPLY_BATCH "$BATCH" 1 100
knob SECRETS_APPLY_SSH_TIMEOUT_S "${SECRETS_APPLY_SSH_TIMEOUT_S:-15}" 3 120       # lane.secrets-apply.secrets_apply_ssh_timeout_s
knob SECRETS_APPLY_PROBE_TIMEOUT_S "${SECRETS_APPLY_PROBE_TIMEOUT_S:-30}" 5 300   # lane.secrets-apply.secrets_apply_probe_timeout_s
WINDOW="${SECRETS_APPLY_ALERT_WINDOW_S:-3600}"       # lane.secrets-apply.secrets_apply_alert_window_s
knob SECRETS_APPLY_ALERT_WINDOW_S "$WINDOW" 300 86400

exec 9>"$H/locks/secrets-apply.lock"
flock -n 9 || exit 0

if [ -z "$(printf '%s' "${ENVELOPE_HUB_TOKEN:-}" | tr -d '[:space:]')" ]; then
  line "not-configured (no ENVELOPE_HUB_TOKEN)"; exit 0
fi

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" >/dev/null 2>&1 || { line "worker-failed (jobs-client did not load)"; exit 0; }
# shellcheck source=bin/lib/envelope.sh
. "$SELF/lib/envelope.sh" || exit 0

KEY="${ENVELOPE_KEY:-/etc/harness/envelope.key}"
NOW="${ENVELOPE_NOW:-$(date +%s)}"
export ENVELOPE_KEY="$KEY" ENVELOPE_NOW="$NOW"
TTL=$(setting_get secret_envelope_ttl_s 2>/dev/null) || TTL=""
[[ "$TTL" =~ ^[0-9]+$ ]] && [ "$TTL" -ge 60 ] && [ "$TTL" -le 86400 ] || TTL=900   # fallback of settings row secret_envelope_ttl_s
for k in "$KEY".*; do
  [ -f "$k" ] || continue
  ts="${k##*.}"; [[ "$ts" =~ ^[0-9]+$ ]] || continue
  if [ $((NOW - ts)) -ge "$TTL" ]; then rm -f "$k" && line "pruned rotated key ${k##*/}"; fi
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/secapply.XXXXXX") || exit 0
trap 'rm -rf "$TMP"' EXIT

CODE=$(envelope_req GET "/api/secrets/envelope?state=pending&limit=$BATCH" "$TMP/pending.json")
case "$CODE" in
  200) ;;
  401|403|503)
    alert --id secrets-apply:hub-token --severity warn secrets-apply \
      "hub token not accepted (http $CODE) on the pending list. Set the same ENVELOPE_HUB_TOKEN on the hub and the jobs worker."
    line "worker-refused (http $CODE)"; exit 0 ;;
  *) line "worker-failed (http $CODE)"; exit 0 ;;
esac
jq -e '(.envelopes|type) == "array"' "$TMP/pending.json" >/dev/null 2>&1 || { line "worker-failed (bad pending answer)"; exit 0; }
PENDING=$(jq '.envelopes | length' "$TMP/pending.json")
TRUNC=$(jq -r 'if .truncated then "true" else "false" end' "$TMP/pending.json")

if [ "$PENDING" -gt 0 ] && [ ! -r "$KEY" ]; then
  STAMP="$H/state/secrets-apply-nokey.stamp"
  LAST=$(cat "$STAMP" 2>/dev/null); [[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0
  if [ $((NOW - LAST)) -ge "$WINDOW" ]; then
    printf '%s\n' "$NOW" > "$STAMP"
    alert --id secrets-apply:no-key --severity warn secrets-apply "$PENDING secret envelope(s) are pending and the hub has no key at $KEY. Run bin/envelope-keygen.sh."
  fi
  line "tick pending=$PENDING consumed=0 failed=0 skipped=$PENDING truncated=$TRUNC (no key)"
  exit 0
fi

# registered <project> — rc 0 when bin/fleet-conf.sh --projects lists it. The
# list is read once per tick, and only when a project scope is pending.
PROJECTS=""; PROJECTS_READ=0
registered() {
  if [ "$PROJECTS_READ" = 0 ]; then
    PROJECTS=$("$SELF/fleet-conf.sh" --projects 2>/dev/null) || PROJECTS=""
    PROJECTS_READ=1
  fi
  grep -qxF -- "$1" <<< "$PROJECTS"
}

CONSUMED=0; FAILED=0; SKIPPED=0
while IFS=$'\t' read -r id scope; do
  [ -n "$id" ] || continue
  case "$scope" in ai-account:*|fleet:*) ;; *) SKIPPED=$((SKIPPED + 1)); continue ;; esac
  # A project scope whose project is not registered yet stays pending (BH-7968).
  # The Onboard form seals the new project's own account before the onboarding
  # run's register station writes the registry row. The read deletes the
  # envelope and envelope-consume.sh refuses an unknown project after the read,
  # so a consume now would lose the secret. The run consumes it after register;
  # a project that never registers lets the envelope expire (the sweep).
  IFS=: read -r _ _ _ use proj _ <<< "$scope"
  if [ "$use" = project ] && [ -n "$proj" ] && ! registered "$proj"; then
    SKIPPED=$((SKIPPED + 1)); line "held $id (project $proj not registered)"; continue
  fi
  "$SELF/envelope-consume.sh" "$id" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) CONSUMED=$((CONSUMED + 1)) ;;
    3) SKIPPED=$((SKIPPED + 1)) ;;
    75) FAILED=$((FAILED + 1)); line "stopped at $id (rc 75)"; break ;;
    *) FAILED=$((FAILED + 1)) ;;
  esac
done < <(jq -r '.envelopes[] | [.id, .scope] | @tsv' "$TMP/pending.json")
line "tick pending=$PENDING consumed=$CONSUMED failed=$FAILED skipped=$SKIPPED truncated=$TRUNC"
exit 0

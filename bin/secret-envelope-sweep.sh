#!/bin/bash
# bin/secret-envelope-sweep.sh — BH-7965 (BH-7937.2): the hourly secret
# envelope sweep on the hub (cron/lanes/774-secret-envelope-sweep.cron). No LLM call.
#
# One POST /api/secrets/envelope/sweep {"dry_run":true|false} (main bearer).
# The jobs worker deletes expired envelopes nobody read, archives and then
# deletes events older than settings row secret_envelope_events_retention_days,
# batch-bounded by secret_envelope_sweep_batch, and writes ONE `sweep` event.
# SECRET_ENVELOPE_SWEEP_DRY_RUN (default 1, dry-run first) only counts.
#
# Exit 0 on a 200 (one ALERTS line when the archive copy failed). 1 on a bad
# knob (one ALERTS line, no request) or a 4xx. 75 when the worker does not
# answer or answers 5xx.
# Log line (logs/secret-envelope-sweep.log):
#   <ts> sweep dry_run=<b> envelopes=<n> events=<n> archive=<word> more=<b>
# OFF: flags/lane-off-secret-envelope-sweep. Registry: catalog/lanes.d/secret-envelope-sweep.json.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit secret-envelope-sweep
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply secret-envelope-sweep

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/secret-envelope-sweep.log"
line() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG"; }
alert() { "$SELF/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

DRY="${SECRET_ENVELOPE_SWEEP_DRY_RUN:-1}"   # lane.secret-envelope-sweep.secret_envelope_sweep_dry_run
case "$DRY" in
  1) BODY='{"dry_run":true}' ;;
  0) BODY='{"dry_run":false}' ;;
  *) alert --id secret-envelope-sweep:knob --severity warn secret-envelope-sweep \
       "SECRET_ENVELOPE_SWEEP_DRY_RUN=$DRY is not 0 or 1; the sweep did not run."
     line "refused: SECRET_ENVELOPE_SWEEP_DRY_RUN not 0 or 1"; exit 1 ;;
esac

exec 9>"$H/locks/secret-envelope-sweep.lock"
flock -n 9 || exit 0

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" || { line "worker-failed (jobs-client did not load)"; exit 75; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/envsweep.XXXXXX") || exit 75
trap 'rm -rf "$TMP"' EXIT
export JOBS_STATUS_FILE="$TMP/status"
if ! _jobs_req POST /api/secrets/envelope/sweep "$BODY" > "$TMP/out.json"; then
  ST=$(cat "$TMP/status" 2>/dev/null)
  case "$ST" in
    http=4*) line "refused (${ST})"; exit 1 ;;
  esac
  line "worker-failed (${ST:-no answer})"; exit 75
fi
FIELDS=$(jq -r '"dry_run=\(.dry_run) envelopes=\(.envelopes) events=\(.events) archive=\(.archive|gsub(" ";"-")) more=\(.more)"' "$TMP/out.json" 2>/dev/null) \
  || { line "worker-failed (bad sweep answer)"; exit 75; }
line "sweep $FIELDS"
if [ "$(jq -r '.archive' "$TMP/out.json")" = failed ]; then
  alert --id secret-envelope-sweep:archive --severity warn secret-envelope-sweep \
    "The secret envelope event archive copy failed. No event was deleted. See logs/secret-envelope-sweep.log."
else
  alert --resolve --id secret-envelope-sweep:archive secret-envelope-sweep "The secret envelope event archive copy works again."
fi
exit 0

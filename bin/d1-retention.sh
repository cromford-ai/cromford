#!/bin/bash
# bin/d1-retention.sh — BH-6750 (slice 2 of BH-6727): the scheduled D1
# retention. Hub only, every hour at :41 (cron/lanes/731-d1-retention.cron).
# No LLM call.
#
# One run: POST /api/retention/run {}. The jobs worker
# (worker/jobs/src/routes/retention.js) does the work in D1: for each rule it
# deletes the eligible rows in bounded batches (settings rows retention.batch
# and retention.max_rows) and writes one retention_runs row. While the
# settings row retention.dry_run is 1 (the seed), it only counts. This script
# writes one log line per rule and one summary line, and alerts when the
# worker does not answer or a rule reports an error.
#
# WHY A HUB LANE AND NOT A WORKER CRON TRIGGER. harness-jobs has no
# `triggers.crons` and no scheduled handler; every D1 housekeeping job today
# (the wakes prune in bin/doorbell-coverage-check.sh, the lane-run wait tick)
# is a hub lane that calls a worker route. Same shape here, so the lane gate,
# the hub lease and the alert path are the ones every other lane uses.
#
# WHY HOURLY. A run removes at most retention.max_rows (5000) per rule. Hourly
# runs drain a backlog in steps instead of one daily burst on a database that
# answered "overloaded" on 2026-10-14.
#
# Exit 0 on every path:
#   no JOBS_URL or no HARNESS_SECRET: `not-configured`, no request, no alert.
#   the worker does not answer 2xx: ONE warn alert, id d1-retention:unreachable.
#   a rule with an error: ONE warn alert per rule, id d1-retention:<rule>.
#   a good answer resolves the ids that are fine.
#
# Log lines (logs/d1-retention.log):
#   <ts> <rule> dry=<0|1> counted=<n> removed=<n> backlog=<0|1>[ off][ error=<text>]
#   <ts> run <run_id> dry=<0|1> rules=<n> removed=<n> errors=<n>
#   | <ts> not-configured (<no-url|no-secret>) | <ts> worker-failed (<why>)
#
# Env: D1_RETENTION_NOW (epoch seconds that stamp the log lines) is a test seam.
# OFF: flags/lane-off-d1-retention (bin/harness-ctl.sh off d1-retention).
# Registry: catalog/lanes.d/d1-retention.json.
# Doc: docs/notes/2026-10-14-BH-6750-d1-retention.md.
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
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit d1-retention
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply d1-retention

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/d1-retention.log"
stamp() {
  if [[ "${D1_RETENTION_NOW:-}" =~ ^[0-9]+$ ]]; then date -u -d "@$D1_RETENTION_NOW" +%FT%TZ; else date -u +%FT%TZ; fi
}
line() { printf '%s %s\n' "$(stamp)" "$1" >> "$LOG"; }
alert() { "$SELF/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" || { line "worker-failed (jobs-client did not load)"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d1ret.XXXXXX") || { line "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

export JOBS_STATUS_FILE="$TMP/status"
if ! _jobs_req POST /api/retention/run '{}' > "$TMP/run.json" \
   || ! jq -e '(.rules|type) == "array"' "$TMP/run.json" >/dev/null 2>&1; then
  ST=$(cat "$TMP/status" 2>/dev/null)
  case "$ST" in
    no-url|no-secret) line "not-configured ($ST)"; exit 0 ;;
  esac
  alert --id d1-retention:unreachable --severity warn d1-retention \
    "The D1 retention run failed (${ST:-no answer}). No rows were removed."
  line "worker-failed (${ST:-no answer})"
  exit 0
fi
alert --resolve --id d1-retention:unreachable d1-retention "The D1 retention run answers again."

RULE_RE='^[a-z_]+\.[a-z_]+$'
DRY=$(jq -r 'if .dry_run then 1 else 0 end' "$TMP/run.json")
RUN_ID=$(jq -r '.run_id // "-"' "$TMP/run.json")
N=0; REMOVED=0; ERRS=0
while IFS=$'\t' read -r rule counted removed backlog off err; do
  [ -n "$rule" ] || continue
  if ! [[ "$rule" =~ $RULE_RE ]]; then line "skipped unsafe rule name"; continue; fi
  N=$((N + 1))
  [[ "$removed" =~ ^[0-9]+$ ]] || removed=0
  REMOVED=$((REMOVED + removed))
  msg="$rule dry=$DRY counted=$counted removed=$removed backlog=$backlog"
  [ "$off" = true ] && msg="$msg off"
  if [ -n "$err" ]; then
    ERRS=$((ERRS + 1))
    msg="$msg error=$(printf '%s' "$err" | tr -s '[:space:]' ' ' | cut -c1-200)"
    alert --id "d1-retention:$rule" --severity warn d1-retention \
      "D1 retention rule $rule stopped with an error. The other rules ran. See logs/d1-retention.log."
  else
    alert --resolve --id "d1-retention:$rule" d1-retention "D1 retention rule $rule runs again."
  fi
  line "$msg"
done < <(jq -r '.rules[] | [.rule, (.counted|tostring), (.removed|tostring), (if .backlog then "1" else "0" end),
  (if .off then "true" else "false" end), (.error // "")] | @tsv' "$TMP/run.json")
line "run $RUN_ID dry=$DRY rules=$N removed=$REMOVED errors=$ERRS"
exit 0

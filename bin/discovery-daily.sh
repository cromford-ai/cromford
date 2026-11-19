#!/bin/bash
# bin/discovery-daily.sh <project> — BH-9795: the discovery-daily hub lane.
# Once a day per project it reads the project's discovery sources (part 1:
# Sentry), drops known items in code, makes one no-tools model call per
# remaining item, and a rules table in code files an ai-build ticket, comments
# on an open candidate ticket, or marks the item as noise.
#
# THE RUN, in this order (the steps after 5 are dd_run in bin/lib/discovery-daily.sh):
#   1. the project must be a fleet.conf name ([a-z0-9-]+), else usage, rc 2;
#   2. env load, lane_gate_or_exit discovery-daily <project> (flags/all-off,
#      flags/lane-off-discovery-daily, the D1 pause rows), then
#      lane_env_apply discovery-daily <project>. Nothing leaves this box before
#      the gate;
#   3. the self-timeout: the whole run inside DISCOVERY_RUN_TIMEOUT_S (1500);
#   4. flock -n locks/discovery-daily-<project>.lock: a held lock skips the run;
#   5. dd_run: claim the run row, fetch, filter, call, act, summary.
#
# Shares the ledger, cap, filing and model-call code of the sentry-triage lane
# (bin/lib/sentry-triage.sh, BH-5620) through its ST_* parameters.
# Registry: catalog/lanes.d/discovery-daily.json. Doc: docs/DISCOVERY-DAILY.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: discovery-daily.sh <project>" >&2; exit 2; }
[ $# = 1 ] || usage
DD_P=$1
[[ $DD_P =~ ^[a-z0-9-]+$ ]] || usage
DD_FLEET="${FLEET_CONF:-$H/fleet.conf}"
awk -v p="$DD_P" 'NF && $1 !~ /^#/ && $1 == p {f=1} END {exit !f}' "$DD_FLEET" 2>/dev/null \
  || { echo "discovery-daily: no project '$DD_P' in $DD_FLEET" >&2; exit 2; }

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# BH-9820: env/<project>.env, after global.env. The lane takes ONE name from it,
# DISCOVERY_SENTRY_TOKEN (the project's own Sentry token; the adapter falls back
# to SENTRY_API_TOKEN). The file is NOT sourced: the last
# `[export ]DISCOVERY_SENTRY_TOKEN=<v>` line is parsed, one pair of matching
# outer quotes is dropped, and the value is used as text (no eval, no
# expansion). Every other line is ignored. The value is never logged.
dd_project_token() { # dd_project_token <file>: prints the value, rc 1 = no line
  local f=$1 line v
  [ -r "$f" ] || return 1
  line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?DISCOVERY_SENTRY_TOKEN=' "$f" 2>/dev/null | tail -n 1)
  [ -n "$line" ] || return 1
  v=${line#*DISCOVERY_SENTRY_TOKEN=}
  v=${v%$'\r'}
  if [[ $v =~ ^\"(.*)\"[[:space:]]*$ ]] || [[ $v =~ ^\'(.*)\'[[:space:]]*$ ]]; then v=${BASH_REMATCH[1]}
  else v=${v%%[[:space:]]#*}; v=${v%"${v##*[![:space:]]}"}; fi
  printf '%s' "$v"
}
if DD_PTOK=$(dd_project_token "$HENV/$DD_P.env") && [ -n "$DD_PTOK" ]; then
  export DISCOVERY_SENTRY_TOKEN="$DD_PTOK"
fi
unset DD_PTOK

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/untrusted-input.sh" 2>/dev/null || true
  . "$SELF/lib/discovery-daily.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${DISCOVERY_DAILY_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$DISCOVERY_DAILY_FIXTURE"
fi

if [ "${DD_TIMED:-}" != 1 ]; then
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit discovery-daily "${DD_P:-}"
fi
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply discovery-daily "$DD_P"
# Bounded (D21): the whole run inside DISCOVERY_RUN_TIMEOUT_S, after the env
# apply so a settings row applies. The re-exec skips the gate (it passed).
if [ "${DD_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  DD_RUN_TIMEOUT_S=$(_st_knob_int DISCOVERY_RUN_TIMEOUT_S "${DISCOVERY_RUN_TIMEOUT_S:-1500}" 1500 60 3600 2>/dev/null) || DD_RUN_TIMEOUT_S=1500
  [[ $DD_RUN_TIMEOUT_S =~ ^[0-9]+$ ]] || DD_RUN_TIMEOUT_S=1500
  DD_TIMED=1 exec timeout "$DD_RUN_TIMEOUT_S" bash "$0" "$@"
fi
export AGENT_CALL_LANE=discovery-daily
for fn in dd_run st_list_issues job_ledger_row job_ledger_put job_ledger_claim lane_role_model ui_wrap gh_rest_issue_list; do
  command -v "$fn" >/dev/null 2>&1 || { echo "discovery-daily: $fn missing (bin/lib/discovery-daily.sh and its libs)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "discovery-daily: jq is required" >&2; exit 1; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
exec 9>"$H/locks/discovery-daily-$DD_P.lock"
flock -n 9 || exit 0

ST_NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${DISCOVERY_DAILY_NOW:-} =~ ^[0-9]+$ ]]; then ST_NOW=$DISCOVERY_DAILY_NOW; fi
[ -n "$ST_NOW" ] || ST_NOW=$(date -u +%s)
ST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/discovery-daily.XXXXXX") || exit 1
trap 'rm -rf "$ST_TMP"' EXIT

dd_run
exit 0

#!/bin/bash
# bin/sentry-triage.sh — BH-5620 (BH-5611.4): the sentry-triage hub lane. Every
# 30 minutes it reads the new and regressed issues of each Sentry source and
# turns each one into exactly one outcome: an ai-build ticket, a comment on a
# matching open ticket, or noise.
#
# SOURCES (BH-9799), one pass each, in this order:
#   - the default source: Sentry project SENTRY_TRIAGE_PROJECT (default
#     cromford-harness) in org SENTRY_ORG with SENTRY_API_TOKEN, tickets in
#     HARNESS_REPO. Ledger keys, day row, alert ids and summary line as before.
#   - each fleet project p with a `sentry` block in
#     catalog/signal-sources.d/<p>.json (bin/lib/signal-source.sh): that org,
#     slug and token (the row's env name, from the environment or parsed from
#     env/<p>.env), tickets in p's fleet.conf repo (column 2, FLEET_CONF or
#     $H/fleet.conf). Ledger keys <p>:<id> and <p>:<id>:regressed, day row
#     <p>:<YYYY-MM-DD>, list alert id sentry-triage-list-<p>, summary line
#     `<ISO> sentry-triage project=<p> issues=...`. No token or no fleet.conf
#     repo: one log line, nothing read.
# The SENTRY_TRIAGE_* knobs apply to each source; the day caps count per
# source (each source has its own day row).
#
# THE RUN, in this order:
#   1. env load, lane_gate_or_exit sentry-triage (flags/all-off,
#      flags/lane-off-sentry-triage, the D1 pause row of the same name), then
#      lane_env_apply. Nothing leaves this box before the gate;
#   2. flock -n locks/sentry-triage.lock: a held lock skips the tick;
#   3. the default source with no SENTRY_API_TOKEN: one log line, then the
#      registry sources. Steps 4-6 run per source (st_run_source):
#   4. st_list_issues. Non-2xx or not an array: ONE warn `sentry-triage-list`
#      (`sentry-triage-list-<p>` for a registry source) with the HTTP code and
#      Sentry's first 200 bytes; the next source runs;
#   5. st_issue for each issue, most events first (bin/lib/sentry-triage.sh
#      holds the dedup, cap, call and act rules). A ledger outage (the day row
#      included) stops the WHOLE tick: no later source is read, and it is ONE
#      warn `sentry-triage-ledger`. An open-issue list that cannot be read
#      stops only that source;
#   6. one summary line per source in logs/sentry-triage.log:
#      <ISO> sentry-triage [project=<p> ]issues=<n> below_min=<n> terminal=<n> called=<n> filed=<n> commented=<n> noise=<n> failed=<n> capped=<n> healed=<n>
#
# One regression pass per issue in total (ledger key <id>:regressed).
# Registry: catalog/lanes.d/sentry-triage.json. Map: docs/verification-map/entries/BH-5620.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# Bounded (D21): the whole tick inside 25 minutes, under the 30-minute cadence.
if [ "${ST_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  ST_TIMED=1 exec timeout 1500 bash "$0" "$@"
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/untrusted-input.sh" 2>/dev/null || true
  . "$SELF/lib/sentry-triage.sh" 2>/dev/null || true
  . "$SELF/lib/signal-source.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${SENTRY_TRIAGE_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$SENTRY_TRIAGE_FIXTURE"
fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit sentry-triage
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply sentry-triage
export AGENT_CALL_LANE=sentry-triage
for fn in st_issue st_list_issues job_ledger_row job_ledger_put lane_role_model ui_wrap gh_rest_issue_list ss_sentry ss_projects; do
  command -v "$fn" >/dev/null 2>&1 || { echo "sentry-triage: $fn missing (bin/lib/sentry-triage.sh and its libs)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "sentry-triage: jq is required" >&2; exit 1; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
exec 9>"$H/locks/sentry-triage.lock"
flock -n 9 || exit 0

ST_NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${SENTRY_TRIAGE_NOW:-} =~ ^[0-9]+$ ]]; then ST_NOW=$SENTRY_TRIAGE_NOW; fi
[ -n "$ST_NOW" ] || ST_NOW=$(date -u +%s)
ST_DAY=$(date -u -d "@$ST_NOW" +%F)
ST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sentry-triage.XXXXXX") || exit 1
trap 'rm -rf "$ST_TMP"' EXIT
ST_CALLED=0; ST_STOP=""; ST_OPEN=""; ST_MODEL=""; ST_RUNNER=""

alert() { "$H/bin/lane-alert.sh" --severity warn --id "$1" sentry-triage "$2" >/dev/null 2>&1 || true; }

# st_run_source <project-or-empty> <org> <slug> <token> <repo> <list-alert-id>:
# one source's pass (steps 4-6). rc 75 = the ledger is unreadable and the tick
# must make no more calls; rc 0 otherwise.
st_run_source() {
  local p=$1 aid=$6 sl="" code lrc N issue rc peek
  ST_ORG=$2; ST_PROJECT=$3; ST_TOKEN=$4; ST_REPO=$5
  ST_KEY_PREFIX=""; ST_SOURCE_LABEL="the harness's own project"
  if [ -n "$p" ]; then ST_KEY_PREFIX="$p:"; ST_SOURCE_LABEL="fleet project $p"; sl="project=$p "; fi
  ST_OPEN=""; ST_STOP=""; ST_CALLED=0
  rm -f "$ST_TMP/open.json" "$ST_TMP/issues.json"
  code=$(st_list_issues "$ST_TMP/issues.json"); lrc=$?
  if [ "$lrc" != 0 ]; then
    peek=$(head -c 200 "$ST_TMP/issues.json" 2>/dev/null | tr '\n' ' ')
    _st_log "${sl}issue list failed (HTTP $code): $peek"
    alert "$aid" "sentry-triage: Sentry issue list for $ST_ORG/$ST_PROJECT answered HTTP $code: $peek"
    return 0
  fi
  N=$(jq 'length' "$ST_TMP/issues.json")
  [ "$N" -ge 100 ] && _st_log "${sl}page cap 100 reached; the rest waits for a later tick"

  C=([below_min]=0 [terminal]=0 [filed]=0 [commented]=0 [noise]=0 [failed]=0 [capped]=0 [healed]=0)
  rc=0
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    rc=0; st_issue "$issue" || rc=$?
    if [ "$rc" = 75 ]; then
      if [ "${ST_STOP:-}" = ledger ]; then
        _st_log "ledger unreadable; no calls this tick"
        alert sentry-triage-ledger "sentry-triage: the jobs ledger is unreadable; no Sentry issue was triaged this tick"
      fi
      break
    fi
    [ -n "${C[$ST_OUT]+x}" ] && C[$ST_OUT]=$((C[$ST_OUT] + 1))
  done < <(jq -c 'sort_by(-((.count // "0") | tonumber? // 0))[]' "$ST_TMP/issues.json")

  _st_log "${sl}issues=$N below_min=${C[below_min]} terminal=${C[terminal]} called=$ST_CALLED filed=${C[filed]} commented=${C[commented]} noise=${C[noise]} failed=${C[failed]} capped=${C[capped]} healed=${C[healed]}"
  if [ "$rc" = 75 ] && [ "${ST_STOP:-}" = ledger ]; then return 75; fi
  return 0
}

st_knobs
declare -A C
DEF_ORG=$ST_ORG; DEF_PROJECT=$ST_PROJECT; DEF_REPO=$ST_REPO

# 1. The default source.
if [ -z "${SENTRY_API_TOKEN:-}" ]; then
  _st_log "sentry token unset; nothing read"
else
  st_run_source "" "$DEF_ORG" "$DEF_PROJECT" "$SENTRY_API_TOKEN" "$DEF_REPO" sentry-triage-list || exit 0
fi

# 2. Each fleet project with a Sentry source.
FC="${FLEET_CONF:-$H/fleet.conf}"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  src=0; ss_sentry "$p" 2>/dev/null || src=$?
  if [ "$src" != 0 ]; then _st_log "project=$p: signal source row not usable; nothing read"; continue; fi
  if [ -z "$SS_TOKEN" ]; then _st_log "project=$p: $SS_TOKEN_ENV unset; nothing read"; continue; fi
  repo=$(awk -v p="$p" 'NF && $1 !~ /^#/ && $1 == p {print $2; exit}' "$FC" 2>/dev/null)
  if ! [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    _st_log "project=$p: no fleet.conf repo; nothing read"; continue
  fi
  st_run_source "$p" "$SS_ORG" "$SS_SLUG" "$SS_TOKEN" "$repo" "sentry-triage-list-$p" || break
done < <(ss_projects sentry 2>/dev/null)
exit 0

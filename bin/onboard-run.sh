#!/bin/bash
# bin/onboard-run.sh [run-id] — BH-7934.2 (#7949): the onboarding runner. Hub
# only, every minute (cron/lanes/745-onboard-run.cron). No LLM call.
#
# One tick:
#   1. Stale check: GET /api/onboarding/runs?state=running. A run with no beat
#      for ONBOARD_RUN_STALE_MIN minutes gets one warn alert per run per UTC
#      day (id onboard-run:stale_run:<id>:<date>).
#   2. Pick: the run-id argument, else the oldest queued run. None: `idle`.
#   3. Claim: POST /api/onboarding/runs/<id>/beat {claim:true}. A 409 (another
#      runner has it, or it was cancelled): `claim-lost`, exit 0.
#   4. Read the run (GET /api/onboarding/runs/<id>) and set the globals the
#      station lib reads: PROJECT SLUG REPO PROD BOX PREFIX PREFIX_LC BASE
#      TRACKER. Arm the repo's App token and source the station lib.
#   5. Each QUEUED step in ord: beat `running`, run the station in a subshell
#      (stdout and stderr to one file), then beat `done` on rc 0, or `failed`
#      with the last ONBOARD_RUN_EXCERPT_BYTES bytes and obs_error_code on rc
#      != 0 (exit 1). A done step is never run again, so a retry starts at the
#      failed station. A 409 on any beat means the run was cancelled: exit 0.
#
# Stations: register prompt label box clone call obs_<station> from
# bin/lib/onboard-stations.sh (BH-7934.1). An undefined function fails the step
# with station_failed, never done. tracker fails with tracker_not_built until
# wave 3. smoke is obs_smoke below. ready does nothing and beats done, which
# sets the run done.
#
# Exit codes: 0 idle, done, claim lost or cancelled; 1 a station failed (the
# run is failed); 2 the worker is not configured, or did not answer after
# ONBOARD_RUN_TRIES transport attempts, or refused a request; 64 a bad
# argument.
#
# Log lines (logs/onboard-run.log): <ts> idle | claim-lost <id> | not-found <id>
#   | step <id> <station> <done|failed> rc=<n> secs=<n>
#   | failed <id> at <station> code=<code> | cancelled <id> at <station>
#   | done <id> <project> | stale <id> | worker-failed (<status>)
#   | not-configured (<why>)
#
# Env, test seams: ONBOARD_STATIONS_LIB (the station lib path);
#   ONBOARD_RUN_LIB_ONLY=1 defines the functions and runs nothing;
#   ONBOARD_RUN_NOW (epoch seconds) is the stale check's clock.
# OFF: flags/lane-off-onboard-run (bin/harness-ctl.sh off onboard-run).
# Registry: catalog/lanes.d/onboard-run.json. Doc: docs/ONBOARDING.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$H/logs/onboard-run.log"
RUN_ID_RE='^ob_[0-9a-f]{20}$'

line() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG"; }
alert() { "$SELF/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

# obs_error_code — reads a station's captured output on stdin, prints one
# code. The first row that matches wins. The code only picks the fix link the
# setup screen shows (docs/ONBOARDING.md); it never starts an action.
obs_error_code() {
  local out
  out=$(cat)
  if grep -iE 'HTTP 403|Resource not accessible by integration' <<<"$out" | grep -qiE 'label|issues'; then
    echo app_no_issues_write
  elif grep -q 'Could not resolve hostname' <<<"$out"; then
    echo box_unreachable
  elif grep -q 'REGISTRY_ADMIN_TOKEN is unset' <<<"$out"; then
    echo registry_token_missing
  elif grep -qE 'failed to push some refs|! \[rejected\]' <<<"$out"; then
    echo prompt_push_rejected
  elif grep -qE 'Repository not found|Could not resolve to a Repository' <<<"$out"; then
    echo repo_not_found
  else
    echo station_failed
  fi
}

# obs_smoke — the smoke station. Every check runs and prints one line; the
# first failure makes rc 1. Reads only: the gh call is a 1-issue REST list
# through the App token step 4 armed.
obs_smoke() {
  local rc=0 off
  if [ -f "$ROOT/prompts/$PROJECT.md" ]; then echo "smoke ok: prompts/$PROJECT.md exists"
  else echo "smoke FAIL: prompts/$PROJECT.md is missing"; rc=1; fi
  off=$("$ROOT/bin/fleet-conf.sh" "$PROJECT" offset 2>/dev/null)
  if [[ "$off" =~ ^[0-9]+$ ]]; then echo "smoke ok: fleet-conf offset $off"
  else echo "smoke FAIL: fleet-conf.sh $PROJECT offset answered '$off'"; rc=1; fi
  # The issue read goes through the REST list helper (bin/lib/gh-rest-list.sh):
  # `gh issue list` spends the GraphQL bucket (BH-1585), and a hand-built
  # issues call is a direct tracker caller (BH-7919). One page, one row kept.
  if ! command -v gh_rest_issue_list >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-rest-list.sh
    . "$ROOT/bin/lib/gh-rest-list.sh" 2>/dev/null || . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
  fi
  if command -v gh_rest_issue_list >/dev/null 2>&1 && gh_rest_issue_list "$SLUG" open "" 1 >/dev/null 2>&1; then
    echo "smoke ok: REST issue list $SLUG"
  else echo "smoke FAIL: REST issue list $SLUG (status ${GH_REST_STATUS:-000})"; rc=1; fi
  if "$ROOT/bin/postmerge-qa.sh" "$PROJECT" --dry-run >/dev/null 2>&1; then echo "smoke ok: postmerge-qa.sh --dry-run"
  else echo "smoke FAIL: postmerge-qa.sh $PROJECT --dry-run"; rc=1; fi
  if [ "$PROD" != "-" ]; then
    if "$ROOT/bin/healthcheck.sh" "$PROJECT" >/dev/null 2>&1; then echo "smoke ok: healthcheck.sh $PROJECT"
    else echo "smoke FAIL: healthcheck.sh $PROJECT"; rc=1; fi
  fi
  return "$rc"
}

# _obr_station <station> — runs one station; its output is the step's log.
_obr_station() {
  case "$1" in
    register|prompt|label|box|clone)
      if declare -F "obs_$1" >/dev/null; then "obs_$1"
      else echo "obs_$1 is not defined"; return 1; fi ;;
    tracker) echo "tracker connect is not built yet (wave 3)"; return 1 ;;
    smoke) obs_smoke ;;
    ready) echo "ready: every earlier station is done" ;;
    *) echo "unknown station $1"; return 1 ;;
  esac
}

# _obr_code <station> <output-file> — the step's error_code.
_obr_code() {
  case "$1" in
    tracker) echo tracker_not_built ;;
    register|prompt|label|box|clone) if declare -F "obs_$1" >/dev/null; then obs_error_code < "$2"; else echo station_failed; fi ;;
    *) obs_error_code < "$2" ;;
  esac
}

# _obr_req <method> <path> [body] — one worker request; the payload on stdout.
# rc 0 a 2xx, 9 a 409, 2 a 404. Anything else ends the tick here: not
# configured or unreachable after the tries is exit 2 with one alert.
_obr_req() {
  local rc st
  _jobs_req "$@"; rc=$?
  case "$rc" in 0|9|2) [ "$rc" = 0 ] && _obr_ok; return "$rc" ;; esac
  st=$(head -c 64 "$JOBS_STATUS_FILE" 2>/dev/null)
  case "$st" in
    no-url|no-secret)
      line "not-configured ($st)"
      alert --id onboard-run:not-configured --severity warn onboard-run \
        "The onboarding runner has no jobs worker to ask ($st). No onboarding run moves."
      exit 2 ;;
    curl_rc=*|http=5*)
      line "worker-failed ($st)"
      alert --id onboard-run:unreachable --severity warn onboard-run \
        "The onboarding runner could not reach the jobs worker after $ONBOARD_RUN_TRIES tries ($st). No onboarding run moved."
      exit 2 ;;
    *)
      line "worker-failed ($st $1 ${2%%\?*})"
      alert --id "onboard-run:${st/=/-}" --severity warn onboard-run \
        "The jobs worker refused an onboarding runner request ($st $1 ${2%%\?*}). See logs/onboard-run.log."
      exit 2 ;;
  esac
}
_OBR_OK=0
_obr_ok() {
  [ "$_OBR_OK" = 1 ] && return 0
  _OBR_OK=1
  alert --resolve --id onboard-run:unreachable onboard-run "The onboarding runner reaches the jobs worker again."
}

# _obr_beat <body-json> — one step beat. A 409 (cancelled) or 404 ends the
# tick with exit 0 or 1.
_obr_beat() {
  local st rc
  st=$(jq -r '.station' <<<"$1")
  _obr_req POST "/api/onboarding/runs/$ID/beat" "$1" > "$TMP/beat.json"; rc=$?
  case "$rc" in
    9) line "cancelled $ID at $st"; exit 0 ;;
    2) line "not-found $ID"; exit 1 ;;
  esac
}

[ "${ONBOARD_RUN_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit onboard-run
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply onboard-run

if [ $# -gt 1 ] || { [ $# = 1 ] && ! [[ "$1" =~ $RUN_ID_RE ]]; }; then
  echo "usage: onboard-run.sh [ob_<20 hex>]" >&2
  exit 64
fi

mkdir -p "$H/logs" 2>/dev/null
ONBOARD_RUN_TRIES="${ONBOARD_RUN_TRIES:-3}"
[[ "$ONBOARD_RUN_TRIES" =~ ^[1-9][0-9]?$ ]] || ONBOARD_RUN_TRIES=3
ONBOARD_RUN_STALE_MIN="${ONBOARD_RUN_STALE_MIN:-30}"
[[ "$ONBOARD_RUN_STALE_MIN" =~ ^[1-9][0-9]*$ ]] || ONBOARD_RUN_STALE_MIN=30
ONBOARD_RUN_STALE_LIST="${ONBOARD_RUN_STALE_LIST:-20}"
[[ "$ONBOARD_RUN_STALE_LIST" =~ ^[1-9][0-9]*$ ]] || ONBOARD_RUN_STALE_LIST=20
ONBOARD_RUN_EXCERPT_BYTES="${ONBOARD_RUN_EXCERPT_BYTES:-4096}"
[[ "$ONBOARD_RUN_EXCERPT_BYTES" =~ ^[1-9][0-9]*$ ]] || ONBOARD_RUN_EXCERPT_BYTES=4096

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" || { line "worker-failed (jobs-client did not load)"; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/onboard-run.XXXXXX") || { line "worker-failed (mktemp)"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
export JOBS_STATUS_FILE="$TMP/status" JOBS_AUTH_VIA_FILE=1
export JOBS_RETRIES=$((ONBOARD_RUN_TRIES - 1))

# 1. stale check
_obr_req GET "/api/onboarding/runs?state=running&limit=$ONBOARD_RUN_STALE_LIST" > "$TMP/running.json"
NOW="${ONBOARD_RUN_NOW:-}"
[[ "$NOW" =~ ^[0-9]+$ ]] || NOW=$(date -u +%s)
DAY=$(date -u -d "@$NOW" +%F)
while IFS=$'\t' read -r sid sproj sst supd; do
  [[ "$sid" =~ $RUN_ID_RE ]] || continue
  [ -n "$supd" ] || continue
  ts=$(date -u -d "$supd" +%s 2>/dev/null) || continue
  [ $(( (NOW - ts) / 60 )) -ge "$ONBOARD_RUN_STALE_MIN" ] || continue
  line "stale $sid"
  alert --id "onboard-run:stale_run:$sid:$DAY" --severity warn onboard-run \
    "Onboarding run $sid ($sproj) has been running at $sst since $supd with no beat."
done < <(jq -r '.runs[]? | [.id, .project, (.station // "claim"), .updated_at] | @tsv' "$TMP/running.json" 2>/dev/null)

# 2. pick
if [ $# = 1 ]; then
  ID="$1"
else
  _obr_req GET "/api/onboarding/runs?state=queued&limit=1" > "$TMP/queued.json"
  ID=$(jq -r '.runs[0].id // empty' "$TMP/queued.json" 2>/dev/null)
  [ -n "$ID" ] || { line idle; exit 0; }
  [[ "$ID" =~ $RUN_ID_RE ]] || { line "worker-failed (bad run id in the queued list)"; exit 2; }
fi

# 3. claim
_obr_req POST "/api/onboarding/runs/$ID/beat" '{"claim":true}' > "$TMP/claim.json"
case $? in
  9) line "claim-lost $ID"; exit 0 ;;
  2) line "not-found $ID"; exit 64 ;;
esac

# 4. read the run and set the station globals
_obr_req GET "/api/onboarding/runs/$ID" > "$TMP/run.json" || { line "not-found $ID"; exit 1; }
inp() { jq -r --arg k "$1" '.run.inputs[$k] // empty' "$TMP/run.json"; }
PROJECT=$(inp project); SLUG=$(inp repo); REPO="$SLUG"; TRACKER=$(inp tracker)
PROD=$(inp prod); [ -n "$PROD" ] || PROD="-"
BASE=$(inp base); PREFIX=$(inp prefix)
ROOT="$H"
cd "$ROOT" || { line "worker-failed (no $ROOT)"; exit 2; }
# shellcheck source=bin/lib/deployment.sh
. "$ROOT/bin/lib/deployment.sh" 2>/dev/null || . "$SELF/lib/deployment.sh" 2>/dev/null || true
BOX=""
[ "$(inp box)" = shared ] && BOX="${ONBOARD_SHARED_BOX:-}"
[ -n "$BOX" ] || BOX="${HARNESS_BOX_PREFIX-}small"
if [ -z "$PREFIX" ]; then
  # load-project.sh's derivation: the initials of the name's segments.
  PREFIX=$(echo "$PROJECT" | awk -F- '{for(i=1;i<=NF;i++) printf toupper(substr($i,1,1))}')
  [ ${#PREFIX} -ge 2 ] || PREFIX=$(echo "$PROJECT" | cut -c1-2 | tr '[:lower:]' '[:upper:]')
fi
PREFIX_LC=$(echo "$PREFIX" | tr '[:upper:]' '[:lower:]')
export PROJECT SLUG REPO PROD BOX PREFIX PREFIX_LC BASE TRACKER ROOT
# shellcheck source=bin/lib/gh-app-auth.sh
. "$ROOT/bin/lib/gh-app-auth.sh" 2>/dev/null && { gh_auth_for "$SLUG" || true; }
STATIONS_LIB="${ONBOARD_STATIONS_LIB:-$ROOT/bin/lib/onboard-stations.sh}"
# shellcheck source=bin/lib/onboard-stations.sh
. "$STATIONS_LIB" || echo "onboard-run: $STATIONS_LIB did not load" >> "$TMP/lib.err"

# 5. each queued step in ord
mapfile -t TODO < <(jq -r '.steps[] | select(.state == "queued") | .station' "$TMP/run.json")
for st in "${TODO[@]}"; do
  t0=$(date +%s)
  _obr_beat "$(jq -nc --arg s "$st" '{station:$s, state:"running"}')"
  ( _obr_station "$st" ) < /dev/null > "$TMP/$st.out" 2>&1
  src=$?
  [ -s "$TMP/lib.err" ] && cat "$TMP/lib.err" >> "$TMP/$st.out"
  # The tail, without a cut UTF-8 character at its start.
  tail -c "$ONBOARD_RUN_EXCERPT_BYTES" "$TMP/$st.out" | LC_ALL=C sed $'1s/^[\x80-\xbf]*//' > "$TMP/excerpt"
  secs=$(( $(date +%s) - t0 ))
  if [ "$src" = 0 ]; then
    _obr_beat "$(jq -nc --arg s "$st" --rawfile l "$TMP/excerpt" '{station:$s, state:"done", log_excerpt:$l}')"
    line "step $ID $st done rc=0 secs=$secs"
    continue
  fi
  code=$(_obr_code "$st" "$TMP/$st.out")
  _obr_beat "$(jq -nc --arg s "$st" --arg c "$code" --rawfile l "$TMP/excerpt" '{station:$s, state:"failed", log_excerpt:$l, error_code:$c}')"
  line "step $ID $st failed rc=$src secs=$secs"
  line "failed $ID at $st code=$code"
  exit 1
done
line "done $ID $PROJECT"
exit 0

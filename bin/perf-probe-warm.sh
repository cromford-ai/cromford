#!/bin/bash
# bin/perf-probe-warm.sh — BH-9792: the post-deploy warm-up of the perf probe
# (hub cron lane perf-probe-warm, every minute, catalog/lanes.d/perf-probe-warm.json).
# For each valid, enabled row in catalog/perf-probe.d/*.json, in name order:
#   1. poll gate: state/perf-probe/<project>/warm.json last_poll_at; inside
#      PERF_PROBE_WARM_POLL_MIN minutes the project stops here (0 requests)
#   2. locks/perf-probe-<project>.lock with no wait; held: next project, no stamp
#   3. stamp warm.json, then check the row's repo and health_path
#   4. ONE GitHub read of the newest deployment of the row's
#      deploy_environment (default Production) through gh_rest
#   5. `jobs-client.sh perf-probe warm-get`: the same id as the newest
#      perf_probe_warm row stops here (0 app requests)
#   6. ONE statuses read: success warms; failure|error|inactive writes one
#      deploy-failed row; any other state writes nothing
#   7. health preflight: GET <base_url><health_path> until 200, every
#      PERF_PROBE_HEALTH_POLL_S, at most PERF_PROBE_HEALTH_WAIT_S
#   8. ONE ppio_session; pass 1 loads each route once (no rows); pass 2 loads
#      each route once more, with one retry on a broken load (5xx or 000)
#   9. ONE results-put (kind post-deploy, run_key = the deployment id), then
#      warm-put outcome warmed, then ppio_keepwarm_reset
#  10. one line in logs/perf-probe-warm.log:
#      <ts> perf-probe-warm <p> deployment=<id> routes=<n> over=<n> recovered=<n> results=ok|rc=<n> warm=ok|rc=<n>
# Pass-2 outcome per route: first load broken and the retry not broken:
# failed-then-recovered; the retry broken: fail; a 3xx or 4xx: unmeasured (no
# retry); else the budget verdict (over: fail, under: pass). Files no ticket.
# Every path exits 0. 0 LLM calls. GET only to the app, no -L.
#
# Row fields this lane reads (all optional; pp_row_valid ignores them):
#   repo                owner/name of the GitHub repo (absent: one skip line)
#   deploy_environment  the GitHub environment name (default Production)
#   health_path         the preflight path (default /api/health)
# Usage: bin/perf-probe-warm.sh      (cron; HARNESS defaults to /root/harness)
# Env:   PERF_PROBE_NOW (test clock), PERF_PROBE_ALLOW_LOOPBACK=1 (test fake),
#        PERF_PROBE_JOBS_CLIENT (default $HARNESS/bin/jobs-client.sh)
# Note:  docs/notes/2026-11-17-BH-9786-perf-probe.md (Warm-up and keep-warm)
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit perf-probe-warm
# The settings rows of both lanes' knobs reach this run as env (BH-1165).
command -v lane_env_apply >/dev/null 2>&1 && { lane_env_apply perf-probe; lane_env_apply perf-probe-warm; }
# shellcheck source=bin/lib/perf-probe.sh
. "$H/bin/lib/perf-probe.sh" || { echo "perf-probe-warm: bin/lib/perf-probe.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/perf-probe-io.sh
. "$H/bin/lib/perf-probe-io.sh" || { echo "perf-probe-warm: bin/lib/perf-probe-io.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" || { echo "perf-probe-warm: bin/lib/gh-rest.sh did not load" >&2; exit 1; }

LOG="$H/logs/perf-probe-warm.log"
mkdir -p "$H/logs" 2>/dev/null
JC="${PERF_PROBE_JOBS_CLIENT:-$H/bin/jobs-client.sh}"

# knob <lane> <env> <fallback> — the knob, read once. The fallbacks are the
# registry defaults (catalog/lanes.d/perf-probe.json, perf-probe-warm.json),
# for a box with no lane-gate.
knob() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob "$1" "$2")
  [[ $v =~ ^[0-9]+$ ]] || v=$3
  printf '%s' "$v"
}
PERF_PROBE_BUDGET_MS=$(knob perf-probe PERF_PROBE_BUDGET_MS 1000)
PERF_PROBE_BUDGET_BYTES=$(knob perf-probe PERF_PROBE_BUDGET_BYTES 512000)
PERF_PROBE_PAUSE_MS=$(knob perf-probe PERF_PROBE_PAUSE_MS 500)
PERF_PROBE_TIMEOUT_S=$(knob perf-probe PERF_PROBE_TIMEOUT_S 30)
export PERF_PROBE_BUDGET_MS PERF_PROBE_BUDGET_BYTES PERF_PROBE_PAUSE_MS PERF_PROBE_TIMEOUT_S
WARM_ENABLED=$(knob perf-probe-warm PERF_PROBE_WARM_ENABLED 1)
POLL_MIN=$(knob perf-probe-warm PERF_PROBE_WARM_POLL_MIN 5)
HEALTH_WAIT_S=$(knob perf-probe-warm PERF_PROBE_HEALTH_WAIT_S 180)
HEALTH_POLL_S=$(knob perf-probe-warm PERF_PROBE_HEALTH_POLL_S 10)
[ "$WARM_ENABLED" = 0 ] && exit 0
[ "$HEALTH_POLL_S" -ge 1 ] 2>/dev/null || HEALTH_POLL_S=1

NOW=$(_ppio_now_s) || { echo "perf-probe-warm: bad PERF_PROBE_NOW" >&2; exit 1; }
[[ $NOW =~ ^[0-9]+$ ]] || { echo "perf-probe-warm: bad PERF_PROBE_NOW" >&2; exit 1; }
NOW_ISO=$(_ppio_iso "$NOW")
DAY=${NOW_ISO%%T*}

plog() { printf '%s perf-probe-warm %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG"; }

kv() { local w; for w in $1; do [ "${w%%=*}" = "$2" ] && [ "$w" != "$2" ] && { printf '%s' "${w#*=}"; return 0; }; done; return 0; }
int_or_null() { [[ ${1:-} =~ ^[0-9]+$ ]] && printf '%d' "$((10#$1))" || printf 'null'; }
# broken <status> — rc 0 when a load is broken: 5xx or no answer (000).
broken() { [[ ${1:-000} == 5* ]] || [ "${1:-000}" = 000 ]; }

# stamp <project> <last_skip> — warm.json {last_poll_at: now, last_skip}.
stamp() { jq -cn --arg t "$NOW_ISO" --arg s "$2" '{last_poll_at: $t, last_skip: $s}' | ppio_state_put "$1" warm; }

# skip_once <project> <why> — one `skip: <why>` line only when the reason
# differs from the last one (a per-minute lane must not repeat it).
skip_once() {
  local prev
  prev=$(ppio_state_get "$1" warm | jq -r '.last_skip // empty' 2>/dev/null)
  [ "$prev" = "$2" ] || plog "$1" "skip: $2"
  stamp "$1" "$2"
}

# warm_put <project> <id> <outcome> <routes> <over> — rc of the client.
warm_put() {
  "$JC" perf-probe warm-put "$(jq -cn --arg p "$1" --arg d "$2" --arg o "$3" --argjson r "$4" --argjson v "$5" \
    '{project: $p, deployment_id: $d, outcome: $o, routes: $r, over: $v}')" >/dev/null 2>&1
}

# load_once <url> <jar> <project> <row> — one load line; a 401 asks
# ppio_on_ended once and retries once. rc 1 when the session ended.
load_once() {
  local line
  line=$(ppio_load "$1" "$2")
  if [ "${line%% *}" = 401 ]; then
    if ppio_on_ended "$3" "$4"; then line=$(ppio_load "$1" "$2"); fi
    [ "${line%% *}" = 401 ] && return 1
  fi
  printf '%s\n' "$line"
}

# health_ok <url> — rc 0 when the url answers 200 inside HEALTH_WAIT_S.
health_ok() {
  local code t0=$SECONDS
  while :; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$PERF_PROBE_TIMEOUT_S" "$1" 2>/dev/null)
    [ "$code" = 200 ] && return 0
    [ $((SECONDS - t0 + HEALTH_POLL_S)) -le "$HEALTH_WAIT_S" ] || return 1
    sleep "$HEALTH_POLL_S"
  done
}

# warm <project> <row-file> — one project, poll gate to log line.
warm() {
  local p="$1" row="$2" last lasts repo envn hp f id state jar base run i route lf v word st tt tot by
  local n=0 over=0 rec=0 rows="[]" outcome nl nb first ob rc rres rwarm
  local -a routes
  pp_row_valid "$row" >/dev/null 2>&1 || return 0
  [ "$(jq -r '.enabled == true' "$row")" = true ] || return 0
  last=$(ppio_state_get "$p" warm | jq -r '.last_poll_at // empty' 2>/dev/null)
  if [ -n "$last" ] && lasts=$(date -u -d "$last" +%s 2>/dev/null) && [ $((NOW - lasts)) -lt $((POLL_MIN * 60)) ]; then
    return 0
  fi
  ppio_lock "$p" 0 || return 0
  repo=$(jq -r 'if (.repo|type) == "string" then .repo else "" end' "$row")
  envn=$(jq -r 'if (.deploy_environment|type) == "string" and .deploy_environment != "" then .deploy_environment else "Production" end' "$row")
  hp=$(jq -r 'if (.health_path|type) == "string" then .health_path else "/api/health" end' "$row")
  if [ -z "$repo" ]; then skip_once "$p" "no repo"; ppio_unlock; return 0; fi
  if ! [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then skip_once "$p" "repo is not owner/name"; ppio_unlock; return 0; fi
  if ! _pp_path_ok "$hp"; then skip_once "$p" "health_path does not start with /"; ppio_unlock; return 0; fi
  # Stamped BEFORE the GitHub read: a failing read waits POLL_MIN, not a minute.
  stamp "$p" ""
  run="$H/state/perf-probe/$p/warm-run"
  case "$run" in "$H"/state/perf-probe/?*/warm-run) rm -rf "$run" ;; esac
  mkdir -p "$run"
  f="$run/gh.json"
  rc=0
  GH_REST_OPTIONAL=1 gh_rest GET "repos/$repo/deployments?environment=$(jq -rn --arg e "$envn" '$e|@uri')&per_page=1" > "$f" || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    plog "$p" "deployments unreadable ($GH_REST_STATUS ${GH_REST_REASON:-rc=$rc})"; ppio_unlock; return 0
  fi
  if [ "$(jq 'length' "$f")" = 0 ]; then ppio_unlock; return 0; fi
  id=$(jq -r '.[0].id | tostring' "$f")
  if ! [[ $id =~ ^[A-Za-z0-9._:-]{1,80}$ ]]; then plog "$p" "deployment id unusable"; ppio_unlock; return 0; fi
  # The watermark. An unknown watermark is never read as "new".
  rc=0
  "$JC" perf-probe warm-get "$p" > "$run/warm-get.json" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then plog "$p" "warm-get rc=$rc"; ppio_unlock; return 0; fi
  if [ "$(jq -r '.row.deployment_id // empty' "$run/warm-get.json" 2>/dev/null)" = "$id" ]; then ppio_unlock; return 0; fi
  rc=0
  GH_REST_OPTIONAL=1 gh_rest GET "repos/$repo/deployments/$id/statuses?per_page=1" > "$f" || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    plog "$p" "statuses unreadable ($GH_REST_STATUS ${GH_REST_REASON:-rc=$rc})"; ppio_unlock; return 0
  fi
  state=$(jq -r '.[0].state // "pending"' "$f")
  case "$state" in
    success) ;;
    failure|error|inactive)
      rc=0; warm_put "$p" "$id" deploy-failed 0 0 || rc=$?
      plog "$p" "deploy-failed $id $state$([ "$rc" = 0 ] || echo " warm=rc=$rc")"
      ppio_unlock; return 0 ;;
    *) ppio_unlock; return 0 ;;
  esac
  base=$(jq -r '.base_url' "$row")
  if ! health_ok "$base$hp"; then
    plog "$p" "health $hp not 200 after ${HEALTH_WAIT_S}s, deployment $id not warmed"; ppio_unlock; return 0
  fi
  if ! jar=$(ppio_session "$p" "$row"); then
    plog "$p" "skip: session ${jar#skip:}"; ppio_unlock; return 0
  fi
  mapfile -t routes < <(pp_routes "$p" "$row")
  # Pass 1: each route once, no rows.
  for route in "${routes[@]}"; do
    case "$route" in '!incomplete'*|'') continue ;; esac
    if ! load_once "$base$route" "$jar" "$p" "$row" >/dev/null; then
      plog "$p" "stop: session ended"; ppio_unlock; return 0
    fi
  done
  # Pass 2: each route once more, one retry on a broken load; one row each.
  i=0
  for route in "${routes[@]}"; do
    case "$route" in '!incomplete'*|'') continue ;; esac
    i=$((i + 1)); lf="$run/$i.loads"
    if ! load_once "$base$route" "$jar" "$p" "$row" > "$lf"; then
      plog "$p" "stop: session ended"; ppio_unlock; return 0
    fi
    first=$(cut -d' ' -f1 "$lf")
    if broken "$first"; then
      if ! load_once "$base$route" "$jar" "$p" "$row" >> "$lf"; then
        plog "$p" "stop: session ended"; ppio_unlock; return 0
      fi
    fi
    v=$(pp_route_verdict "$row" "$route" "$lf")
    word=${v%% *}
    read -r st tt tot by _ < <(grep -v '^[[:space:]]*$' "$lf" | tail -n 1)
    case "$word" in over|under|unmeasured) ;; *) word=unmeasured ;; esac
    nl=$(grep -c . "$lf"); nb=0
    while read -r s _; do broken "$s" && nb=$((nb + 1)); done < "$lf"
    ob=0
    if [ "$nl" -gt 1 ] && ! broken "$st"; then
      outcome=failed-then-recovered; rec=$((rec + 1))
      [ "$word" = over ] && ob=1
    elif [ "$nl" -gt 1 ]; then
      outcome=fail; ob=1
    elif [[ $st == [34]* ]]; then
      outcome=unmeasured
    else
      case "$word" in over) outcome=fail; ob=1 ;; unmeasured) outcome=unmeasured ;; *) outcome=pass ;; esac
      [ -n "$(kv "$v" outcome)" ] && outcome=$(kv "$v" outcome)
    fi
    rows=$(jq -c --arg route "$route" \
      --argjson ttfb "$(int_or_null "$(kv "$v" ttfb_ms)")" --argjson ttfb0 "$(int_or_null "${tt:-}")" \
      --argjson total "$(int_or_null "$(kv "$v" total_ms)")" --argjson total0 "$(int_or_null "${tot:-}")" \
      --argjson bytes "$(int_or_null "$(kv "$v" bytes)")" --argjson bytes0 "$(int_or_null "${by:-}")" \
      --argjson status "$(int_or_null "$(kv "$v" status)")" --argjson status0 "$(int_or_null "${st:-}")" \
      --argjson loads "$nl" --argjson breaks "$nb" --argjson ob "$ob" --arg outcome "$outcome" \
      '. + [{route: $route, ttfb_ms: ($ttfb // $ttfb0), total_ms: ($total // $total0),
             bytes: ($bytes // $bytes0), status: ($status // $status0), over_budget: $ob,
             outcome: $outcome, loads: $loads, breaks: $breaks}]' <<<"$rows")
    n=$((n + 1))
    [ "$ob" = 1 ] && over=$((over + 1))
  done
  rres=ok
  if [ "$n" -gt 0 ]; then
    rc=0
    "$JC" perf-probe results-put "$(jq -cn --arg p "$p" --arg d "$DAY" --arg k "$id" --argjson rows "$rows" \
      '{project: $p, day: $d, kind: "post-deploy", run_key: $k, rows: $rows}')" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || rres="rc=$rc"
  fi
  # The warm-up happened, so the watermark is written even when the results
  # were lost: a permanent 4xx must not re-warm every POLL_MIN.
  rc=0; warm_put "$p" "$id" warmed "$n" "$over" || rc=$?
  rwarm=ok; [ "$rc" = 0 ] || rwarm="rc=$rc"
  ppio_keepwarm_reset "$p"
  plog "$p" "deployment=$id routes=$n over=$over recovered=$rec results=$rres warm=$rwarm"
  ppio_unlock
  return 0
}

while IFS= read -r ROW; do
  [ -f "$ROW" ] || continue
  warm "$(basename "$ROW" .json)" "$ROW"
done < <(printf '%s\n' "$H"/catalog/perf-probe.d/*.json | LC_ALL=C sort)
exit 0

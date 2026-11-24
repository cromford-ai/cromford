#!/bin/bash
# bin/perf-probe.sh — BH-9786: the daily perf probe (hub cron lane perf-probe,
# 06:17Z, catalog/lanes.d/perf-probe.json). For each project row in
# catalog/perf-probe.d/*.json, in name order:
#   1. pp_row_valid; an invalid or disabled row is one skip line, 0 requests
#   2. locks/perf-probe-<project>.lock, waited at most PERF_PROBE_LOCK_WAIT_S
#   3. ppio_session: one session POST with the project's internal token
#      (or an unexpired jar from an earlier run)
#   4. each route of pp_routes: pp_loads_per_route GETs (ppio_load), then the
#      verdict of pp_route_verdict; a 401 load asks ppio_on_ended
#   5. ONE `jobs-client.sh perf-probe results-put` for all rows (D1
#      perf_probe_results, kind daily, run_key daily: a rerun upserts)
#   6. pp_statements_run, pp_ticket_step, ppio_keepwarm_reset
#   7. one line in logs/perf-probe.log:
#      <ts> perf-probe <project> routes=<n> over=<n> stmts_new=<n> ticket=<a> complete|incomplete
# complete = every route loaded (no !incomplete marker, no stop) AND the
# results-put answered rc 0. Every path exits 0: a skipped project is not a
# failure. 0 LLM calls. GET only to the app, no -L.
#
# Usage: bin/perf-probe.sh            (cron; HARNESS defaults to /root/harness)
# Env:   PERF_PROBE_NOW (test clock), PERF_PROBE_ALLOW_LOOPBACK=1 (test fake),
#        PERF_PROBE_JOBS_CLIENT (default $HARNESS/bin/jobs-client.sh)
# Note:  docs/notes/2026-11-17-BH-9786-perf-probe.md
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit perf-probe
# The settings rows of the knobs below reach this run as env (BH-1165).
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply perf-probe
# shellcheck source=bin/lib/perf-probe.sh
. "$H/bin/lib/perf-probe.sh" || { echo "perf-probe: bin/lib/perf-probe.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/perf-probe-io.sh
. "$H/bin/lib/perf-probe-io.sh" || { echo "perf-probe: bin/lib/perf-probe-io.sh did not load" >&2; exit 1; }

LOG="$H/logs/perf-probe.log"
mkdir -p "$H/logs" 2>/dev/null
JC="${PERF_PROBE_JOBS_CLIENT:-$H/bin/jobs-client.sh}"

# The knobs, read once (catalog/lanes.d/perf-probe.json). The code fallbacks
# below are the registry defaults, for a box with no lane-gate.
knob() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob perf-probe "$1")
  [[ $v =~ ^[0-9]+$ ]] || v=$2
  printf '%s' "$v"
}
PERF_PROBE_BUDGET_MS=$(knob PERF_PROBE_BUDGET_MS 1000)
PERF_PROBE_BUDGET_BYTES=$(knob PERF_PROBE_BUDGET_BYTES 512000)
PERF_PROBE_PAUSE_MS=$(knob PERF_PROBE_PAUSE_MS 500)
PERF_PROBE_TIMEOUT_S=$(knob PERF_PROBE_TIMEOUT_S 30)
PERF_PROBE_LOCK_WAIT_S=$(knob PERF_PROBE_LOCK_WAIT_S 600)
export PERF_PROBE_BUDGET_MS PERF_PROBE_BUDGET_BYTES PERF_PROBE_PAUSE_MS PERF_PROBE_TIMEOUT_S PERF_PROBE_LOCK_WAIT_S

if [ -n "${PERF_PROBE_NOW:-}" ]; then
  DAY=$(date -u -d "$PERF_PROBE_NOW" +%Y-%m-%d 2>/dev/null) || { echo "perf-probe: bad PERF_PROBE_NOW" >&2; exit 1; }
else
  DAY=$(date -u +%Y-%m-%d)
fi

plog() { printf '%s perf-probe %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG"; }

# kv <verdict line> <key> — the value of key=value in the verdict, or empty.
kv() { local w; for w in $1; do [ "${w%%=*}" = "$2" ] && [ "$w" != "$2" ] && { printf '%s' "${w#*=}"; return 0; }; done; return 0; }
# int_or_null <v> — v when a whole number, else null (JSON).
int_or_null() { [[ ${1:-} =~ ^[0-9]+$ ]] && printf '%d' "$((10#$1))" || printf 'null'; }

# probe <project> <row-file> — one project, start to log line.
probe() {
  local p="$1" row="$2" why sess jar base run i route lf loads k line v word st tt tot by n over complete stopped rows rc stmts ticket outcome
  local -a routes
  why=$(pp_row_valid "$row") || { plog "$p" "skip: invalid row $why"; return 0; }
  [ "$(jq -r '.enabled == true' "$row")" = true ] || { plog "$p" "skip: disabled"; return 0; }
  ppio_lock "$p" "$PERF_PROBE_LOCK_WAIT_S" || { plog "$p" "skip: lock busy"; return 0; }
  if ! sess=$(ppio_session "$p" "$row"); then
    plog "$p" "skip: session ${sess#skip:}"
    ppio_unlock; return 0
  fi
  jar=$sess
  base=$(jq -r '.base_url' "$row")
  run="$H/state/perf-probe/$p/run"
  case "$run" in "$H"/state/perf-probe/?*/run) rm -rf "$run" ;; esac
  mkdir -p "$run"
  complete=1; stopped=0; n=0; over=0; i=0; rows="[]"
  mapfile -t routes < <(pp_routes "$p" "$row")
  for route in "${routes[@]}"; do
    case "$route" in
      '!incomplete'*) complete=0; continue ;;
      '') continue ;;
    esac
    i=$((i + 1)); lf="$run/$i.loads"; : > "$lf"
    loads=$(pp_loads_per_route); [[ $loads =~ ^[0-9]+$ ]] && [ "$loads" -ge 1 ] || loads=1
    k=0
    while [ "$k" -lt "$loads" ]; do
      line=$(ppio_load "$base$route" "$jar")
      if [ "${line%% *}" = 401 ]; then
        if ppio_on_ended "$p" "$row"; then line=$(ppio_load "$base$route" "$jar"); fi
        if [ "${line%% *}" = 401 ]; then stopped=1; break; fi
      fi
      printf '%s\n' "$line" >> "$lf"
      k=$((k + 1))
    done
    if [ "$stopped" = 1 ]; then plog "$p" "stop: session ended"; complete=0; break; fi
    v=$(pp_route_verdict "$row" "$route" "$lf")
    word=${v%% *}
    read -r st tt tot by _ < <(grep -v '^[[:space:]]*$' "$lf" | tail -n 1)
    case "$word" in over|under|unmeasured) ;; *) word=unmeasured ;; esac
    case "$word" in over) outcome=fail ;; unmeasured) outcome=unmeasured ;; *) outcome=pass ;; esac
    [ -n "$(kv "$v" outcome)" ] && outcome=$(kv "$v" outcome)
    rows=$(jq -c --arg route "$route" \
      --argjson ttfb "$(int_or_null "$(kv "$v" ttfb_ms)")" --argjson ttfb0 "$(int_or_null "${tt:-}")" \
      --argjson total "$(int_or_null "$(kv "$v" total_ms)")" --argjson total0 "$(int_or_null "${tot:-}")" \
      --argjson bytes "$(int_or_null "$(kv "$v" bytes)")" --argjson bytes0 "$(int_or_null "${by:-}")" \
      --argjson status "$(int_or_null "$(kv "$v" status)")" --argjson status0 "$(int_or_null "${st:-}")" \
      --argjson loads "$(int_or_null "$(kv "$v" loads)")" --argjson loads0 "$(grep -c . "$lf")" \
      --argjson breaks "$(int_or_null "$(kv "$v" breaks)")" \
      --argjson ob "$([ "$word" = over ] && echo 1 || echo 0)" --arg outcome "$outcome" \
      '. + [{route: $route, ttfb_ms: ($ttfb // $ttfb0), total_ms: ($total // $total0),
             bytes: ($bytes // $bytes0), status: ($status // $status0), over_budget: $ob,
             outcome: $outcome, loads: ($loads // $loads0), breaks: ($breaks // $ob)}]' <<<"$rows")
    n=$((n + 1))
    [ "$word" = over ] && over=$((over + 1))
  done
  if [ "$n" -gt 0 ]; then
    "$JC" perf-probe results-put "$(jq -cn --arg p "$p" --arg d "$DAY" --argjson rows "$rows" \
      '{project: $p, day: $d, kind: "daily", run_key: "daily", rows: $rows}')" >/dev/null 2>&1
    rc=$?
    [ "$rc" = 0 ] || { plog "$p" "results-put rc=$rc"; complete=0; }
  fi
  stmts=$(pp_statements_run "$p" "$row" "$run" "$DAY"); [ -n "$stmts" ] || stmts=stmts_new=0
  ticket=$(pp_ticket_step "$p" "$row" "$DAY" "$run"); [ -n "$ticket" ] || ticket=ticket=none
  ppio_keepwarm_reset "$p"
  plog "$p" "routes=$n over=$over $stmts $ticket $([ "$complete" = 1 ] && echo complete || echo incomplete)"
  ppio_unlock
  return 0
}

while IFS= read -r ROW; do
  [ -f "$ROW" ] || continue
  probe "$(basename "$ROW" .json)" "$ROW"
done < <(printf '%s\n' "$H"/catalog/perf-probe.d/*.json | LC_ALL=C sort)
exit 0

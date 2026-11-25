#!/bin/bash
# bin/perf-probe-keepwarm.sh — BH-9792: the keep-warm lane of the perf probe
# (hub cron lane perf-probe-keepwarm, every minute,
# catalog/lanes.d/perf-probe-keepwarm.json). Keep-warm is ON by default (the operator,
# 2026-11-17: "just make it on"). For each valid, enabled row in
# catalog/perf-probe.d/*.json with keepwarm != false, in name order:
#   1. state/perf-probe/<project>/keepwarm.json {last_at, fails, paused}:
#      paused, or a round inside PERF_PROBE_KEEPWARM_MIN minutes: next project
#   2. locks/perf-probe-<project>.lock with no wait; held: next project
#   3. ppio_session (an unexpired jar is reused: 0 POSTs)
#   4. GET the first PERF_PROBE_KEEPWARM_ROUTES routes once each (ppio_load);
#      a 401 asks ppio_on_ended once and retries once
#   5. the round passed when at least one load answered 2xx: fails 0; else
#      fails + 1, and at PERF_PROBE_KEEPWARM_FAIL_MAX: paused, one line
#      <ts> perf-probe-keepwarm <p> keepwarm paused fails=<n>
# A paused project makes 0 requests until ppio_keepwarm_reset (the daily lane
# bin/perf-probe.sh and the warm-up bin/perf-probe-warm.sh call it), which
# writes {"fails":0}. No result row, no ticket, no other line. Every path exits
# 0. 0 LLM calls. GET only to the app, no -L.
# Usage: bin/perf-probe-keepwarm.sh  (cron; HARNESS defaults to /root/harness)
# Env:   PERF_PROBE_NOW (test clock), PERF_PROBE_ALLOW_LOOPBACK=1 (test fake)
# Note:  docs/notes/2026-11-17-BH-9786-perf-probe.md (Warm-up and keep-warm)
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit perf-probe-keepwarm
# The settings rows of both lanes' knobs reach this run as env (BH-1165).
command -v lane_env_apply >/dev/null 2>&1 && { lane_env_apply perf-probe; lane_env_apply perf-probe-keepwarm; }
# shellcheck source=bin/lib/perf-probe.sh
. "$H/bin/lib/perf-probe.sh" || { echo "perf-probe-keepwarm: bin/lib/perf-probe.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/perf-probe-io.sh
. "$H/bin/lib/perf-probe-io.sh" || { echo "perf-probe-keepwarm: bin/lib/perf-probe-io.sh did not load" >&2; exit 1; }

LOG="$H/logs/perf-probe-keepwarm.log"
mkdir -p "$H/logs" 2>/dev/null

# knob <lane> <env> <fallback> — the knob, read once. The fallbacks are the
# registry defaults (catalog/lanes.d/perf-probe.json, perf-probe-keepwarm.json),
# for a box with no lane-gate.
knob() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob "$1" "$2")
  [[ $v =~ ^[0-9]+$ ]] || v=$3
  printf '%s' "$v"
}
PERF_PROBE_PAUSE_MS=$(knob perf-probe PERF_PROBE_PAUSE_MS 500)
PERF_PROBE_TIMEOUT_S=$(knob perf-probe PERF_PROBE_TIMEOUT_S 30)
export PERF_PROBE_PAUSE_MS PERF_PROBE_TIMEOUT_S
KW_MIN=$(knob perf-probe-keepwarm PERF_PROBE_KEEPWARM_MIN 5)
KW_ROUTES=$(knob perf-probe-keepwarm PERF_PROBE_KEEPWARM_ROUTES 10)
KW_FAIL_MAX=$(knob perf-probe-keepwarm PERF_PROBE_KEEPWARM_FAIL_MAX 3)
[ "$KW_MIN" = 0 ] && exit 0

NOW=$(_ppio_now_s) || { echo "perf-probe-keepwarm: bad PERF_PROBE_NOW" >&2; exit 1; }
[[ $NOW =~ ^[0-9]+$ ]] || { echo "perf-probe-keepwarm: bad PERF_PROBE_NOW" >&2; exit 1; }
NOW_ISO=$(_ppio_iso "$NOW")

plog() { printf '%s perf-probe-keepwarm %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG"; }

# round <project> <row-file> — rc 0 when at least one load answered 2xx.
round() {
  local p="$1" row="$2" jar base route line k=0 passed=1
  local -a routes
  jar=$(ppio_session "$p" "$row") || return 1
  base=$(jq -r '.base_url' "$row")
  mapfile -t routes < <(pp_routes "$p" "$row")
  for route in "${routes[@]}"; do
    case "$route" in '!incomplete'*|'') continue ;; esac
    [ "$k" -lt "$KW_ROUTES" ] || break
    k=$((k + 1))
    line=$(ppio_load "$base$route" "$jar")
    if [ "${line%% *}" = 401 ]; then
      ppio_on_ended "$p" "$row" || return "$passed"
      line=$(ppio_load "$base$route" "$jar")
    fi
    [[ ${line%% *} == 2* ]] && passed=0
  done
  return "$passed"
}

# keepwarm <project> <row-file> — one project, state read to state write.
keepwarm() {
  local p="$1" row="$2" st last lasts fails
  pp_row_valid "$row" >/dev/null 2>&1 || return 0
  [ "$(jq -r '.enabled == true and .keepwarm != false' "$row")" = true ] || return 0
  st=$(ppio_state_get "$p" keepwarm)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$st" || st='{}'
  [ "$(jq -r '.paused == true' <<<"$st" 2>/dev/null)" = true ] && return 0
  last=$(jq -r '.last_at // empty' <<<"$st" 2>/dev/null)
  if [ -n "$last" ] && lasts=$(date -u -d "$last" +%s 2>/dev/null) && [ $((NOW - lasts)) -lt $((KW_MIN * 60)) ]; then
    return 0
  fi
  fails=$(jq -r '.fails // 0' <<<"$st" 2>/dev/null)
  [[ $fails =~ ^[0-9]+$ ]] || fails=0
  ppio_lock "$p" 0 || return 0
  if round "$p" "$row"; then
    jq -cn --arg t "$NOW_ISO" '{last_at: $t, fails: 0}' | ppio_state_put "$p" keepwarm
  else
    fails=$((fails + 1))
    if [ "$fails" -ge "$KW_FAIL_MAX" ]; then
      jq -cn --arg t "$NOW_ISO" --argjson f "$fails" '{last_at: $t, fails: $f, paused: true}' | ppio_state_put "$p" keepwarm
      plog "$p" "keepwarm paused fails=$fails"
    else
      jq -cn --arg t "$NOW_ISO" --argjson f "$fails" '{last_at: $t, fails: $f}' | ppio_state_put "$p" keepwarm
    fi
  fi
  ppio_unlock
  return 0
}

while IFS= read -r ROW; do
  [ -f "$ROW" ] || continue
  keepwarm "$(basename "$ROW" .json)" "$ROW"
done < <(printf '%s\n' "$H"/catalog/perf-probe.d/*.json | LC_ALL=C sort)
exit 0

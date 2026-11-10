#!/bin/bash
# bin/lib/triage-gate-relay.sh — does a relay json at gate time buy a triage
# run? (BH-9324, the triage-gate reader of BH-8364). Sourced, never run;
# defines functions only.
#
# bin/triage-gate.sh answers `RUN remote-results-pending` when a *.json is in
# state/remote-results/<p>/. Staging runs before the gate on every tick and
# moves every json it reads, so a json at gate time is often a hub re-send of
# a json this box consumed already (the pool relay retry, the custody sweep).
# Staging consumes that json as `duplicate` on its next pass anyway, so a paid
# run for it does nothing.
#
# tgr_relay_run asks the rr-consumed row of each json (rrr_consumed). Only when
# EVERY json has a `staged` or `duplicate` row (the set staging itself treats
# as consumed, bin/lib/rt/staging.sh) does it say "no run". Every unknown
# answer (no row, an outage, no client, `empty`/`badjson`/`parked`, a row with
# no status, more jsons than the cap, the knob at 0) is today's RUN. A read
# can only REMOVE a false run. It never stages, moves or deletes a file.
#
# Knob: TRIAGE_GATE_RR_ROWS_MAX on the run-triage lane
# (catalog/lanes.d/run-triage.knobs.d/TRIAGE_GATE_RR_ROWS_MAX.json).
# Tests: tests/triage-gate-relay.bh-9324-test.sh.

# Root per docs/notes/2026-09-26-BH-2613-lib-root-resolution.md: the entry
# point owns the default; with no root, only the sibling path is tried.
_TGR_R="${HARNESS:-${H:-}}"
for _TGR_P in "$(dirname "${BASH_SOURCE[0]}")/rr-relay.sh" ${_TGR_R:+"$_TGR_R/bin/lib/rr-relay.sh"}; do
  # shellcheck source=bin/lib/rr-relay.sh
  [ -r "$_TGR_P" ] && { . "$_TGR_P"; break; }
done
unset _TGR_P _TGR_R

# _tgr_cap — the cap: lane_knob, else the env, else 20.
_tgr_cap() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob run-triage TRIAGE_GATE_RR_ROWS_MAX 2>/dev/null); fi
  [ -n "$v" ] || v="${TRIAGE_GATE_RR_ROWS_MAX:-}"
  # fallback 20: settings row lane.run-triage.triage_gate_rr_rows_max
  # (catalog/lanes.d/run-triage.knobs.d/TRIAGE_GATE_RR_ROWS_MAX.json)
  [[ $v =~ ^[0-9]{1,6}$ ]] || v=20
  printf '%s\n' "$((10#$v))"
}

# tgr_relay_run <project> <dir> — rc 0 = the json check gives RUN (today's
#   answer); rc 1 = every *.json in <dir> is consumed per its rr-consumed row
#   (or there is none), so the check gives no run reason. Prints nothing.
#   Reads at most the cap, and stops at the first json that is not consumed.
tgr_relay_run() {
  local p="${1:-}" d="${2:-}" cap f st
  local -a js=()
  for f in "$d"/*.json; do [ -f "$f" ] && js+=("$f"); done
  [ "${#js[@]}" -gt 0 ] || return 1
  cap=$(_tgr_cap)
  [ "$cap" -gt 0 ] || return 0
  [ "${#js[@]}" -le "$cap" ] || return 0
  command -v rrr_consumed >/dev/null 2>&1 || return 0
  for f in "${js[@]}"; do
    st=$(rrr_consumed "$p" "$f") || return 0
    case "$st" in staged|duplicate) ;; *) return 0 ;; esac
  done
  return 1
}

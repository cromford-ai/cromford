#!/bin/bash
# bin/lib/closeout-owed.sh — BH-9879: an owed PR close-out wakes the triage
# gate before the queue step.
#
# project-3 TK-747, 2026-11-21: a staged builds/project-3-TK-747-remote<ts>/ dir held
# `PR_CREATED https://… | MIGRATION GATE: …` and no COMMENTED. project-3 always has
# a ready queue, so bin/triage-gate.sh step 2 always exited first (`RUN
# queue-pending`, whose scope carries no result dirs, then `SKIP
# queue-unchanged` for 45 minutes). Step 3, the results sweep, never ran.
# bin/triage-gate.sh step 1f asks co_owed_dirs; when it prints a dir the gate
# answers `RUN results-sweep` under step 3's own sweepfp brake.
#
#   co_knobs [project]
#     Applies the settings contract once per process (lib_env_apply
#     closeout-owed), then sets _CO_WAKE (0/1), _CO_MAX_AGE (s) and _CO_BRAKE
#     (s) in THIS shell.
#
#   co_owed_dirs <harness> <project>
#     One dir per line (no trailing slash) for every builds/<p>-*/ and
#     builds/pool-<p>-*/ dir where: RESULT exists; no COMMENTED; line 1 is
#     `PR_CREATED http…` or `PR_MERGED http…`; bd_closed_out says no; the
#     dir is not held by prod_red_defers_dir; RESULT is younger than
#     _CO_MAX_AGE. Always rc 0. Call co_knobs first.
#
# KNOBS (catalog/lanes.d/_lib.closeout-owed.json; numbers below are the
# documented fallback only): CLOSEOUT_OWED_WAKE (1, 0 = off),
# CLOSEOUT_OWED_MAX_AGE_S (21600), CLOSEOUT_OWED_BRAKE_S (2700).
# Sourced, never executed. Functions only, safe under `set -u`.
# Tests: tests/closeout-owed-gate.bh-9879-test.sh.
# shellcheck shell=bash
if [ -n "${CLOSEOUT_OWED_LIB:-}" ]; then return 0 2>/dev/null; fi
CLOSEOUT_OWED_LIB=1
_CO_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_CO_APPLIED=0
# bd_closed_out is the one "already delivered" test. No lib = no marker test,
# and a marked dir is then owed only until its staging COMMENTED-marks it.
if ! command -v bd_closed_out >/dev/null 2>&1; then
  # shellcheck source=bin/lib/builder-direct.sh
  [ -r "$_CO_LIBDIR/builder-direct.sh" ] && . "$_CO_LIBDIR/builder-direct.sh" 2>/dev/null
fi

# _co_int <value> <fallback> <min> <max> — a clamped integer.
_co_int() {
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  v=$((10#$v))
  [ "$v" -lt "$3" ] && v="$3"
  [ "$v" -gt "$4" ] && v="$4"
  printf '%s' "$v"
}

co_knobs() {
  if [ "$_CO_APPLIED" = 0 ]; then
    _CO_APPLIED=1
    if [ "${LANE_GATE_DISABLE:-0}" != 1 ] && ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_CO_LIBDIR/lane-gate.sh" ] && . "$_CO_LIBDIR/lane-gate.sh" 2>/dev/null
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply closeout-owed "${1:-}"
  fi
  # Fallbacks name their rows in catalog/lanes.d/_lib.closeout-owed.json:
  # lib.closeout-owed.CLOSEOUT_OWED_WAKE, ...CLOSEOUT_OWED_MAX_AGE_S,
  # ...CLOSEOUT_OWED_BRAKE_S. The clamps are that file's min/max.
  _CO_WAKE="${CLOSEOUT_OWED_WAKE:-1}"
  case "$_CO_WAKE" in 0|1) ;; *) _CO_WAKE=1 ;; esac
  _CO_MAX_AGE=$(_co_int "${CLOSEOUT_OWED_MAX_AGE_S:-21600}" 21600 600 604800)
  _CO_BRAKE=$(_co_int "${CLOSEOUT_OWED_BRAKE_S:-2700}" 2700 600 14400)
  return 0
}

co_owed_dirs() {
  local h="${1:-}" p="${2:-}" d l m now
  [ -n "$h" ] && [ -n "$p" ] || return 0
  [ -n "${_CO_MAX_AGE:-}" ] || co_knobs "$p"
  now=$(date +%s)
  for d in "$h/builds/$p"-*/ "$h/builds/pool-$p"-*/; do
    [ -f "$d/RESULT" ] && [ ! -f "$d/COMMENTED" ] || continue
    l=$(head -1 "$d/RESULT" 2>/dev/null)
    case "$l" in PR_CREATED\ http*|PR_MERGED\ http*) ;; *) continue ;; esac
    command -v bd_closed_out >/dev/null 2>&1 && bd_closed_out "$l" && continue
    command -v prod_red_defers_dir >/dev/null 2>&1 && prod_red_defers_dir "$h" "$p" "$d" && continue
    m=$(stat -c %Y "$d/RESULT" 2>/dev/null || stat -f %m "$d/RESULT" 2>/dev/null || echo 0)
    [ $(( now - ${m:-0} )) -lt "$_CO_MAX_AGE" ] || continue
    printf '%s\n' "${d%/}"
  done
  return 0
}

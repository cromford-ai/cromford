#!/bin/bash
# bin/lib/triage-gate-untriaged.sh — BH-9885. Two helpers for the queue-gates
# brake in bin/triage-gate.sh step 2.
#
# THE INCIDENT. project-3, 2026-11-21: three queued tickets waited on open PRs whose
# state did not move, so every tick printed `SKIP queue-gates-unchanged`. That
# SKIP exits before step 6 (the board diff), and nine new tickets waited for
# the 4 h hard recheck. The gate now asks tgu_untriaged_rows before that SKIP.
#
# Sourced, never run. Sets no shell options.

_TGU_LIBDIR=$(dirname "${BASH_SOURCE[0]}")

# tgu_hard_recheck_s <project> — the queue-gates hard recheck, in seconds.
# Settings row: lib.triage-gate.<project>.queue_gate_hard_recheck_s, else
# lib.triage-gate.queue_gate_hard_recheck_s (registry: catalog/lanes.d/
# _lib.triage-gate.json). Code fallback 14400 when there is no row and no env.
# Junk, or a value under 2700 (the 45-minute queue-unchanged window, which a
# smaller value would disable), is replaced by 14400.
tgu_hard_recheck_s() {
  local v
  if ! command -v lib_env_apply >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-gate.sh
    [ -r "$_TGU_LIBDIR/lane-gate.sh" ] && . "$_TGU_LIBDIR/lane-gate.sh" 2>/dev/null
  fi
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply triage-gate "${1:-}" >/dev/null 2>&1
  v="${QUEUE_GATE_HARD_RECHECK_S:-14400}"
  case "$v" in ''|*[!0-9]*) v=14400 ;; esac
  [ "${#v}" -le 9 ] && [ "$v" -ge 2700 ] || v=14400
  printf '%s\n' "$v"
}

# tgu_untriaged_rows <stored-fp-file> <live-fp-file> — prints `<key>\t<id>`
# for each row that must reach triage:
#   (a) NEW: its id is not in the same key of the stored fingerprint (or the
#       stored fingerprint has no such key);
#   (b) MOVED AND UNVERDICTED: the stored row differs from the live row, and the
#       live row has a `triageVerdict` key whose value is null or "".
# Keys `prs` and `meta` are never read. A row whose `state` is CLOSED is never a
# trigger. Row identity is .id, else .number (the identity bin/gate-diff.sh uses).
# rc 0 = at least one row; rc 1 = none; rc 2 = an input is missing or not a
# JSON object. Both inputs are files, never argv.
tgu_untriaged_rows() {
  local out
  [ -r "${1:-}" ] && [ -r "${2:-}" ] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  out=$(jq -nr --slurpfile old "$1" --slurpfile new "$2" '
    def ident: (if .id != null then .id else .number end) | tostring;
    ($old[0]) as $o | ($new[0]) as $n
    | if ($o | type) != "object" or ($n | type) != "object" then error("not an object") else . end
    | $n | to_entries[]
    | select(.key != "prs" and .key != "meta" and (.value | type) == "array")
    | .key as $k
    | (($o[$k] // []) | if type == "array" then . else [] end
       | map(select(type == "object") | {key: ident, value: .}) | from_entries) as $om
    | .value[] | select(type == "object")
    | select(((.state // "") | tostring | ascii_upcase) != "CLOSED")
    | ident as $id
    | select(($om | has($id) | not)
             or (($om[$id] != .) and has("triageVerdict")
                 and (.triageVerdict == null or .triageVerdict == "")))
    | "\($k)\t\($id)"' 2>/dev/null) || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

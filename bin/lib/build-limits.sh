# shellcheck shell=bash
# bin/lib/build-limits.sh — cap the CPU a build session takes on the box that
# runs it (BH-8281). Sourced by bin/run-build.sh and bin/fix-round-claim.sh;
# defining functions is its only effect.
#
# WHY. On 2026-10-24 box-project-6-os-1 (10.0.0.14) reached a load average of
# 92. From 11:20Z to 18:14Z the hub could not ssh to it, so the project-6-os
# pool logged `env bundle FAILED … ssh env extract from 10.0.0.14 failed
# (ssh rc 255)` on every tick and no project-6 build started for 7 hours. Six
# project-6 fix rounds on the same box ended rc=137. The box had just taken
# project-6-desktop, a Rust/cargo build, which by default runs one rustc job per
# core at the same priority as sshd and the cron lanes.
#
# bl_apply <harness> <project>
#   1. CARGO_BUILD_JOBS: exported from knob BUILD_CARGO_JOBS (0 = auto, half the
#      cores, at least 1). A CARGO_BUILD_JOBS that is already set and not empty
#      (the project env file, an operator) wins and is left alone.
#   2. Niceness: the CALLING shell ($BASHPID) is reniced to knob BUILD_NICE
#      (0 = off), only when its niceness is lower. Never raised back. Children
#      (claude, cargo, rustc) inherit it, so sshd, cron and the pool ticks win
#      the CPU under contention. Call it in the shell whose children must yield,
#      never in a $( … ) — that would renice the substitution's subshell.
#   Knobs: catalog/lanes.d/_lib.build-limits.json, resolved through
#   lib_env_apply build-limits <project> in a subshell (row
#   lib.build-limits.<project>.<knob> > row lib.build-limits.<knob> > env >
#   registry default). rc 0 always; nothing on stdout; one stderr line with
#   what was applied, read back after the renice:
#     build-limits: <project> CARGO_BUILD_JOBS=<n> nice=<n>
_BL_LIB="$(dirname "${BASH_SOURCE[0]}")"
_bl_digits() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
# _bl_default <ENV> <fallback> — the knob's default in this checkout's registry
# file. <fallback> is the code fallback of that same row
# (catalog/lanes.d/_lib.build-limits.json), used only when the file is unreadable.
_bl_default() {
  local v
  v=$(jq -r --arg e "$1" '.libs[]? | select(.id == "build-limits") | .knobs[]?
                          | select(.env == $e) | .default // empty' \
        "$_BL_LIB/../../catalog/lanes.d/_lib.build-limits.json" 2>/dev/null)
  _bl_digits "$v" || v="$2"
  printf '%s' "$v"
}
# _bl_nice — the current niceness of this process tree, or 0.
_bl_nice() {
  local n; n=$(nice 2>/dev/null)
  case "$n" in ''|*[!0-9-]*) n=0 ;; esac
  printf '%s' "$n"
}
bl_apply() {
  local h="${1:-${HARNESS:-}}" p="${2:-}" r jobs want cores cur
  r=$(
    export HARNESS="$h"
    lg="$h/bin/lib/lane-gate.sh"
    [ -r "$lg" ] || lg="$_BL_LIB/lane-gate.sh"
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply build-limits "$p" >/dev/null 2>&1
    printf '%s|%s' "${BUILD_CARGO_JOBS:-}" "${BUILD_NICE:-}"
  ) || r="|"
  IFS='|' read -r jobs want <<<"$r"
  _bl_digits "$jobs" || jobs=$(_bl_default BUILD_CARGO_JOBS 0)
  _bl_digits "$want" || want=$(_bl_default BUILD_NICE 10)
  if [ -z "${CARGO_BUILD_JOBS:-}" ]; then
    if [ "$jobs" -eq 0 ]; then
      cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)
      _bl_digits "$cores" || cores=1
      jobs=$((cores / 2)); [ "$jobs" -ge 1 ] || jobs=1
    fi
    export CARGO_BUILD_JOBS="$jobs"
  fi
  [ "$want" -le 19 ] || want=19
  cur=$(_bl_nice)
  if [ "$want" -gt 0 ] && [ "$cur" -lt "$want" ]; then
    renice -n "$want" -p "$BASHPID" >/dev/null 2>&1 || :
  fi
  printf 'build-limits: %s CARGO_BUILD_JOBS=%s nice=%s\n' "${p:-?}" "$CARGO_BUILD_JOBS" "$(_bl_nice)" >&2
  return 0
}

#!/bin/bash
# bin/lib/pool-rootfs.sh — the rootfs size of a pool machine (BH-8640, the
# rest of BH-8499 Fix 3). Sourced by bin/fly-pool.sh; spawn_one adds
# ${PRFS_ARGS[@]} (`--rootfs-size <GB>`, or nothing) to `fly machine run`.
#
# The input is the fly-pool lane knob ROOTFS_GB, exported by lane_env_apply
# from row lane.fly-pool.<project>.rootfs_gb
# (catalog/lanes.d/fly-pool.knobs.d/ROOTFS_GB.json). 0 or no row = no flag,
# the Fly default rootfs: the argv before this knob, byte for byte.
#
# POOL_ROOTFS_GB_MAX (100) is the knob's registry `max`, repeated here so the
# lib refuses what the control plane refuses. Fly's own limit is not checked.
#
# An older flyctl has no --rootfs-size flag and refuses the whole launch, so a
# valid row is used only when `fly machine run --help` lists the flag. The
# probe runs only for a valid nonzero row (no row = no new fly call) and its
# answer is cached for the process in _PRFS_FLAG_OK (1 or 0). The probe is cut
# after POOL_ROOTFS_PROBE_TIMEOUT_S seconds (row
# lane.fly-pool.<project>.pool_rootfs_probe_timeout_s, fallback 20, 1..120); a
# cut probe reads as "no flag". The probe is fly_machines_run_help in
# bin/lib/vendor/fly-machines.sh.
#
# pool_rootfs_resolve -> sets PRFS_GB, PRFS_ARGS (array), PRFS_WHY.
# rc 0 = no flag, or the flag is used (PRFS_WHY empty); rc 1 = the row is set
# but not used, and PRFS_WHY says why. It never exits.

POOL_ROOTFS_GB_MAX=100

# The help probe goes through the fly-machines vendor seam (BH-7939 B3: no
# `machine run` call outside bin/lib/vendor/). No seam = no probe = no flag.
# shellcheck source=bin/lib/vendor/fly-machines.sh
. "${BASH_SOURCE[0]%/*}/vendor/fly-machines.sh" 2>/dev/null || true

pool_rootfs_resolve() {
  local g="${ROOTFS_GB:-}" h="" to="${POOL_ROOTFS_PROBE_TIMEOUT_S:-}"
  # Trim the blanks and newlines a settings row or env file can carry.
  g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"
  PRFS_GB=0 PRFS_ARGS=() PRFS_WHY=""
  [ -n "$g" ] || return 0
  case "$g" in
    *[!0-9]*) PRFS_WHY="rootfs_gb '$g' is not a whole number of GB in 1..$POOL_ROOTFS_GB_MAX"; return 1 ;;
  esac
  # Strip leading zeros so bash does not read the number as octal.
  g="${g#"${g%%[!0]*}"}"; [ -n "$g" ] || return 0
  if [ "${#g}" -gt 3 ] || [ "$g" -gt "$POOL_ROOTFS_GB_MAX" ]; then
    PRFS_WHY="rootfs_gb '$g' is not a whole number of GB in 1..$POOL_ROOTFS_GB_MAX"; return 1
  fi
  if [ -z "${_PRFS_FLAG_OK:-}" ]; then
    # 20 is the documented fallback of knob POOL_ROOTFS_PROBE_TIMEOUT_S.
    case "$to" in ''|*[!0-9]*) to=20 ;; esac
    to="${to#"${to%%[!0]*}"}"
    { [ -n "$to" ] && [ "${#to}" -le 3 ] && [ "$to" -le 120 ]; } || to=20
    command -v fly_machines_run_help >/dev/null 2>&1 && { h=$(fly_machines_run_help "$to") || true; }
    case "$h" in *--rootfs-size*) _PRFS_FLAG_OK=1 ;; *) _PRFS_FLAG_OK=0 ;; esac
  fi
  if [ "$_PRFS_FLAG_OK" != 1 ]; then
    PRFS_WHY="flyctl has no --rootfs-size flag"; return 1
  fi
  PRFS_GB="$g" PRFS_ARGS=(--rootfs-size "$g")
  return 0
}

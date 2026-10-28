#!/bin/bash
# bin/lib/pool-vm-size.sh — the Fly guest size and memory of a pool machine
# (BH-8318, MKF-3). Sourced by bin/fly-pool.sh; spawn_one passes the answer as
# `--vm-size "$PVM_SIZE" --vm-memory "$PVM_MEM"` on `fly machine run`.
#
# The inputs are two fly-pool lane knobs, exported by lane_env_apply:
#   VM_SIZE       row lane.fly-pool.<project>.vm_size       (fallback performance-8x)
#   VM_MEMORY_MB  row lane.fly-pool.<project>.vm_memory_mb  (fallback 16384)
# performance-8x / 16384 below are the documented fallback of those knobs
# (catalog/lanes.d/fly-pool.knobs.d/VM_SIZE.json, VM_MEMORY_MB.json).
#
# The allow-list is Fly's own performance-class guest limits, not a tunable:
# a size is performance-1x|2x|4x|8x|16x (exact), and its memory is a multiple
# of 1024 MB between 2048 and 8192 MB per CPU. Any check that fails sends the
# WHOLE pair back to the fallback, because a good size with the fallback
# memory can be a pair flyctl refuses (performance-16x with 16384).
#
# pool_vm_resolve -> sets PVM_SIZE, PVM_MEM, PVM_WHY. rc 0 = the pair is used
# (PVM_WHY empty); rc 1 = the fallback pair is used and PVM_WHY says why.
# Pure bash: no fork, no file read.

pool_vm_resolve() {
  local s="${VM_SIZE:-}" m="${VM_MEMORY_MB:-}" cpus=""
  # Trim the blanks and newlines a settings row or env file can carry.
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  m="${m#"${m%%[![:space:]]*}"}"; m="${m%"${m##*[![:space:]]}"}"
  PVM_SIZE=performance-8x PVM_MEM=16384 PVM_WHY=""
  [ -n "$s" ] || s=performance-8x
  [ -n "$m" ] || m=16384
  case "$s" in
    performance-1x) cpus=1 ;; performance-2x) cpus=2 ;; performance-4x) cpus=4 ;;
    performance-8x) cpus=8 ;; performance-16x) cpus=16 ;;
    *) PVM_WHY="vm_size '$s' is not one of performance-1x/2x/4x/8x/16x"; return 1 ;;
  esac
  case "$m" in
    ''|*[!0-9]*) PVM_WHY="vm_memory_mb '$m' is not a whole number of MB"; return 1 ;;
  esac
  # Strip leading zeros so bash does not read the number as octal.
  m="${m#"${m%%[!0]*}"}"; [ -n "$m" ] || m=0
  if [ "${#m}" -gt 7 ] || [ $(( m % 1024 )) -ne 0 ]; then
    PVM_WHY="vm_memory_mb '$m' is not a multiple of 1024"; return 1
  fi
  if [ "$m" -lt $(( 2048 * cpus )) ] || [ "$m" -gt $(( 8192 * cpus )) ]; then
    PVM_WHY="vm_memory_mb $m does not fit $s ($(( 2048 * cpus ))..$(( 8192 * cpus )) MB)"; return 1
  fi
  PVM_SIZE="$s" PVM_MEM="$m"
  return 0
}

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
# The allow-list is Fly's own guest limits, not a tunable. Two classes:
#   performance-1x|2x|4x|8x|16x  memory a multiple of 1024 MB, 2048..8192 per CPU
#   shared-cpu-1x|2x|4x|8x       memory a multiple of 256 MB,  256..2048 per CPU
# (shared-cpu since BH-9065). Any check that fails sends the WHOLE pair back to
# the fallback, because a good size with the fallback memory can be a pair
# flyctl refuses (performance-16x with 16384).
#
# pool_vm_resolve -> sets PVM_SIZE, PVM_MEM, PVM_WHY. rc 0 = the pair is used
# (PVM_WHY empty); rc 1 = the fallback pair is used and PVM_WHY says why.
# Pure bash: no fork, no file read.
#
# TWO MACHINE CLASSES PER JOB KIND (BH-9065). A pool job whose work is a model
# session (a plan, a lead review, a re-review) does not need 8 dedicated CPUs.
# Three more fly-pool knobs:
#   VM_CLASS            row lane.fly-pool.<project>.vm_class (fallback
#                       POOL_VM_CLASS_FALLBACK below): `<kind>=<class>` pairs,
#                       blank- or comma-separated. class is model|compute. A
#                       row REPLACES the fallback map; `build=compute` (any
#                       pair that names no model kind) puts every kind on
#                       compute, the behaviour before this knob.
#   VM_SIZE_MODEL       row lane.fly-pool.<project>.vm_size_model
#                       (fallback shared-cpu-2x)
#   VM_MEMORY_MB_MODEL  row lane.fly-pool.<project>.vm_memory_mb_model
#                       (fallback 4096)
# A kind the map does not name, or an unknown class, is `compute`, which reads
# VM_SIZE/VM_MEMORY_MB exactly as before. An absent or empty row is the
# fallback map: plan, lead review and re-review on the model class.
# pool_vm_kind_for_key <key>  -> prints the job kind of a pool key
# pool_vm_job_kind <key> <job-file> -> the same, with a build key's stage
#                                (plan / execute, BH-9065 stage hand-off)
# pool_vm_class_for <kind>    -> prints model|compute
# pool_vm_resolve_for <kind>  -> sets PVM_CLASS too; a refused model pair falls
#                                back to performance-8x/16384 (class compute).

# The documented fallback of the VM_CLASS knob
# (catalog/lanes.d/fly-pool.knobs.d/VM_CLASS.json carries the same string).
# execute, the gate and the test phases run inside a `build` or `execute` job,
# so they are compute; fixround, rebase and preview edit or build code: compute.
POOL_VM_CLASS_FALLBACK="plan=model leadreview=model rereview=model"

pool_vm_resolve() {
  local s="${VM_SIZE:-}" m="${VM_MEMORY_MB:-}" cpus=""
  # Trim the blanks and newlines a settings row or env file can carry.
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  m="${m#"${m%%[![:space:]]*}"}"; m="${m%"${m##*[![:space:]]}"}"
  PVM_SIZE=performance-8x PVM_MEM=16384 PVM_WHY=""
  [ -n "$s" ] || s=performance-8x
  [ -n "$m" ] || m=16384
  # step/lo/hi: the memory rule of the size's class, in MB (per CPU for lo/hi).
  local step=1024 lo=2048 hi=8192
  case "$s" in
    performance-1x) cpus=1 ;; performance-2x) cpus=2 ;; performance-4x) cpus=4 ;;
    performance-8x) cpus=8 ;; performance-16x) cpus=16 ;;
    shared-cpu-1x) cpus=1 ;; shared-cpu-2x) cpus=2 ;; shared-cpu-4x) cpus=4 ;;
    shared-cpu-8x) cpus=8 ;;
    *) PVM_WHY="vm_size '$s' is not one of performance-1x/2x/4x/8x/16x or shared-cpu-1x/2x/4x/8x"; return 1 ;;
  esac
  case "$s" in shared-cpu-*) step=256 lo=256 hi=2048 ;; esac
  case "$m" in
    ''|*[!0-9]*) PVM_WHY="vm_memory_mb '$m' is not a whole number of MB"; return 1 ;;
  esac
  # Strip leading zeros so bash does not read the number as octal.
  m="${m#"${m%%[!0]*}"}"; [ -n "$m" ] || m=0
  if [ "${#m}" -gt 7 ] || [ $(( m % step )) -ne 0 ]; then
    PVM_WHY="vm_memory_mb '$m' is not a multiple of $step for $s"; return 1
  fi
  if [ "$m" -lt $(( lo * cpus )) ] || [ "$m" -gt $(( hi * cpus )) ]; then
    PVM_WHY="vm_memory_mb $m does not fit $s ($(( lo * cpus ))..$(( hi * cpus )) MB)"; return 1
  fi
  PVM_SIZE="$s" PVM_MEM="$m"
  return 0
}

# The key prefixes are the ones the reap and pool_spawn_decision already use.
pool_vm_kind_for_key() {
  case "${1:-}" in
    RR-*) echo rereview ;; LR-*) echo leadreview ;; FXR-*) echo fixround ;;
    RB-*) echo rebase ;; CP-*) echo preview ;; *) echo build ;;
  esac
}

# pool_vm_job_kind <key> <job-file> -> the kind of a queued job: the key's kind,
# and for a build key `execute` when the job carries stage:"execute" (the
# re-offer after a plan hand-off), `plan` when VM_CLASS (or its fallback)
# maps plan=model.
pool_vm_job_kind() {
  local k st
  k=$(pool_vm_kind_for_key "${1:-}")
  if [ "$k" = build ]; then
    st=$(jq -r '.stage // ""' "${2:-/dev/null}" 2>/dev/null)
    if [ "$st" = execute ]; then k=execute
    elif [ "$(pool_vm_class_for plan)" = model ]; then k=plan
    fi
  fi
  echo "$k"
}

pool_vm_class_for() {
  local want="${1:-}" pair k c out=compute; local -a pairs=()
  [ -n "$want" ] || { echo compute; return 0; }
  # read -a, not a bare expansion: a `*` in the row must not glob.
  local raw="${VM_CLASS:-$POOL_VM_CLASS_FALLBACK}"
  read -ra pairs <<<"${raw//,/ }"
  # Exact, case-sensitive match on the kind; the last pair for a kind wins.
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    k="${pair%%=*}"; c="${pair#*=}"
    [ "$k" = "$want" ] && [ "$k" != "$pair" ] || continue
    case "$c" in model|compute) out="$c" ;; *) out=compute ;; esac
  done
  echo "$out"
}

pool_vm_resolve_for() {
  PVM_CLASS=$(pool_vm_class_for "${1:-}")
  if [ "$PVM_CLASS" != model ]; then
    pool_vm_resolve; return $?
  fi
  # The model pair, with its own fallback for an absent row.
  local rc=0
  VM_SIZE="${VM_SIZE_MODEL:-shared-cpu-2x}" VM_MEMORY_MB="${VM_MEMORY_MB_MODEL:-4096}" pool_vm_resolve || rc=1
  [ "$rc" = 0 ] || PVM_CLASS=compute
  return "$rc"
}

#!/bin/bash
# bin/harden-state.sh — set immutable (+i) on env/ssh files, append-only (+a) on ledgers.
#
# Modes:
#   (none)        arm every target
#   --status      print hardened=N/M and exit 0 iff fully hardened (no chattr)
#   --release <p> remove the flag from one in-set file (i for env/ssh, a for a ledger)
#   --rearm  <p>  re-apply the correct flag to one in-set file
#
# The ten ledger names are kept in one array so later slices can source this
# script and read LEDGERS instead of copying the list.

HARNESS="${HARNESS:-/root/harness}"
HARDEN_SSH_DIR="${HARDEN_SSH_DIR:-/root/.ssh}"
LOCK_DIR="$HARNESS/locks"
LOCK_FILE="$LOCK_DIR/harden-state.lock"

LEDGERS=(
  cost.csv
  ALERTS.log
  harden-state.log
  alerts-state.log
  agent-rules.log
  findings.log
  medic.log
  blocked-resolver.log
  READY-QUEUE.log
  extra-usage.csv
)

set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/env-path.sh
. "$BIN/lib/env-path.sh"
ENV_DIR=$(harness_env_dir "$HARNESS")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-harden-state
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off harden-state.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# Only the no-argument arm-all run is the */10 tick (BH-7422). --status,
# --release and --rearm are helper calls, often made while the caller holds
# locks/harden-state.lock, so they never take the one-run claim.
case "${1:-}" in '') ;; *) LANE_SINGLE_RUN=0 ;; esac
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit harden-state
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    harden-state

stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

has_flag() {
  local path="$1" flag="$2"
  local attr
  attr=$(lsattr -d "$path" 2>/dev/null | awk '{print $1}') || return 1
  [[ "$attr" == *"$flag"* ]]
}

chattr_ok() {
  if ! command -v chattr >/dev/null 2>&1 || ! command -v lsattr >/dev/null 2>&1; then
    echo "harden-state: chattr/lsattr not available" >&2
    return 1
  fi
  local probe
  probe=$(mktemp)
  if ! chattr +i "$probe" 2>/dev/null || ! has_flag "$probe" "i"; then
    rm -f "$probe"
    echo "harden-state: chattr not functional (missing privileges or unsupported fs)" >&2
    return 1
  fi
  chattr -i "$probe" 2>/dev/null || true
  rm -f "$probe"
  return 0
}

collect_targets() {
  local -n out_targets=$1
  local -n out_kinds=$2
  out_targets=()
  out_kinds=()
  local f
  while IFS= read -r -d '' f; do
    out_targets+=("$f")
    out_kinds+=("immutable")
  done < <(find "$ENV_DIR" -type f -print0 2>/dev/null)
  for f in "$HARDEN_SSH_DIR/id_ed25519"* "$HARDEN_SSH_DIR/authorized_keys"; do
    if [ -f "$f" ] && ! [ -L "$f" ]; then
      out_targets+=("$f")
      out_kinds+=("immutable")
    fi
  done
  local name
  for name in "${LEDGERS[@]}"; do
    f="$HARNESS/logs/$name"
    if [ -f "$f" ] && ! [ -L "$f" ]; then
      out_targets+=("$f")
      out_kinds+=("append")
    fi
  done
}

classify_existing() {
  local path="$1"
  local rp
  rp=$(realpath "$path" 2>/dev/null) || { echo "out-of-set"; return 0; }
  local env_root logs_root
  env_root=$(realpath -m "$ENV_DIR" 2>/dev/null)
  logs_root=$(realpath -m "$HARNESS/logs" 2>/dev/null)

  if [ -n "$env_root" ] && [[ "$rp" == "$env_root/"* ]] && [ -f "$rp" ]; then
    echo "immutable"
    return 0
  fi
  local tf
  for tf in "$HARDEN_SSH_DIR/id_ed25519"* "$HARDEN_SSH_DIR/authorized_keys"; do
    [ -e "$tf" ] || continue
    if [ "$rp" = "$(realpath "$tf" 2>/dev/null)" ]; then
      echo "immutable"
      return 0
    fi
  done
  if [ -n "$logs_root" ] && [[ "$rp" == "$logs_root/"* ]] && [ -f "$rp" ]; then
    local base
    base=$(basename "$rp")
    for name in "${LEDGERS[@]}"; do
      if [ "$base" = "$name" ]; then
        echo "append"
        return 0
      fi
    done
  fi
  echo "out-of-set"
  return 0
}

lock_run() {
  mkdir -p "$LOCK_DIR"
  (
    exec 8>"$LOCK_FILE"
    flock -w 60 8 || { echo "harden-state: lock timeout" >&2; exit 2; }
    "$@"
  )
}

arm_all() {
  local -a targets=()
  local -a kinds=()
  collect_targets targets kinds
  local M=${#targets[@]}
  local -a changed_paths=()
  local K=0
  local i t kind mode
  for ((i=0; i<M; i++)); do
    t="${targets[$i]}"
    kind="${kinds[$i]}"
    if [ "$kind" = "immutable" ]; then
      mode=""
      mode=$(stat -c '%a' "$t" 2>/dev/null || echo "")
      if [ "$mode" != "600" ]; then
        chmod 600 "$t" 2>/dev/null || true
      fi
      if ! has_flag "$t" "i"; then
        if chattr +i "$t" 2>/dev/null; then
          K=$((K+1))
          changed_paths+=("$t")
        else
          echo "harden-state: failed to chattr +i $t" >&2
          return 1
        fi
      fi
    else
      if ! has_flag "$t" "a"; then
        if chattr +a "$t" 2>/dev/null; then
          K=$((K+1))
          changed_paths+=("$t")
        else
          echo "harden-state: failed to chattr +a $t" >&2
          return 1
        fi
      fi
    fi
  done
  local N=0
  for ((i=0; i<M; i++)); do
    t="${targets[$i]}"
    kind="${kinds[$i]}"
    local flag="i"
    [ "$kind" = "append" ] && flag="a"
    if has_flag "$t" "$flag"; then
      N=$((N+1))
    fi
  done
  echo "hardened=$N/$M changed=$K"
  if [ "$K" -gt 0 ]; then
    printf '%s hardened=%s/%s changed=%s %s\n' "$(stamp)" "$N" "$M" "$K" "${changed_paths[*]}" >> "$HARNESS/logs/harden-state.log"
  fi
  if [ "$N" -eq "$M" ]; then return 0; else return 1; fi
}

do_status() {
  local -a targets=()
  local -a kinds=()
  collect_targets targets kinds
  local M=${#targets[@]}
  local N=0
  local i t kind flag
  for ((i=0; i<M; i++)); do
    t="${targets[$i]}"
    kind="${kinds[$i]}"
    flag="i"
    [ "$kind" = "append" ] && flag="a"
    if has_flag "$t" "$flag"; then
      N=$((N+1))
    fi
  done
  echo "hardened=$N/$M"
  if [ "$N" -eq "$M" ]; then return 0; else return 1; fi
}

do_release() {
  local path="$1"
  if [ ! -e "$path" ]; then
    return 0
  fi
  local kind
  kind=$(classify_existing "$path") || { echo "harden-state: cannot classify $path" >&2; return 2; }
  if [ "$kind" = "out-of-set" ]; then
    echo "harden-state: $path is not in the hardening set" >&2
    return 2
  fi
  # Release the flag the file actually carries, mirroring do_rearm's choice: a
  # ledger is +a, and a rewriter that rewrites it (mv = a new inode) needs that
  # flag off exactly as much as an env file needs -i.
  local flag="i"
  [ "$kind" = "append" ] && flag="a"
  local rp
  rp=$(realpath "$path" 2>/dev/null) || { echo "harden-state: cannot resolve $path" >&2; return 2; }
  if has_flag "$rp" "$flag"; then
    if ! chattr "-$flag" "$rp" 2>/dev/null; then
      echo "harden-state: failed to release $path" >&2
      return 2
    fi
  fi
  return 0
}

do_rearm() {
  local path="$1"
  if [ ! -e "$path" ]; then
    return 0
  fi
  local kind
  kind=$(classify_existing "$path") || { echo "harden-state: cannot classify $path" >&2; return 2; }
  if [ "$kind" = "out-of-set" ]; then
    echo "harden-state: $path is not in the hardening set" >&2
    return 2
  fi
  local flag="i"
  [ "$kind" = "append" ] && flag="a"
  local rp
  rp=$(realpath "$path" 2>/dev/null) || { echo "harden-state: cannot resolve $path" >&2; return 2; }
  if ! has_flag "$rp" "$flag"; then
    if ! chattr "+$flag" "$rp" 2>/dev/null; then
      echo "harden-state: failed to rearm $path" >&2
      return 2
    fi
  fi
  return 0
}

main() {
  if ! chattr_ok; then return 2; fi
  case "${1:-}" in
    '')
      lock_run arm_all
      ;;
    --status)
      lock_run do_status
      ;;
    --release)
      if [ $# -lt 2 ]; then echo "harden-state: --release requires a path" >&2; return 2; fi
      do_release "$2"
      ;;
    --rearm)
      if [ $# -lt 2 ]; then echo "harden-state: --rearm requires a path" >&2; return 2; fi
      do_rearm "$2"
      ;;
    *)
      echo "harden-state: unknown argument $1" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi

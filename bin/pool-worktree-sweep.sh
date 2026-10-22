#!/bin/bash
# bin/pool-worktree-sweep.sh — remove the worktrees of earlier jobs from a pool
# machine before it takes a new build (BH-8004). Runs ON THE MACHINE.
#
# The hub reuses a started pool machine for the next queued job, and a pool
# build names its worktree per key (/root/worktrees/<project>-<key slug>, the
# slot gate is skipped on a pool machine). So each job on a reused machine
# leaves one more worktree on the rootfs (project-6: about 2 GB of
# node_modules each) until the runner's disk guard defers every build there.
#
# Usage: pool-worktree-sweep.sh --root <abs dir> [--keep <name>]... [--proc <dir>] [--harness <dir>]
#   --root     the worktrees root (the runner passes /data/worktrees)
#   --keep     an exact entry name to keep (never a prefix); repeatable
#   --proc     the proc tree to read cwds from (default /proc; a test seam)
#   --harness  the log dir's harness (default ${HARNESS:-/data/harness})
# ONE line on stdout:
#   WTSWEEP ok removed=<n> busy=<n> kept=<n> failed=<n> freed_kb=<k>   exit 0
#   WTSWEEP unreadable <why>   nothing removed                         exit 2
#
# Each entry of the root (dot entries too) is, in this order: kept (a --keep
# name); busy (a live process has its cwd at it or under it) and kept; a symlink,
# whose link alone is removed; a registered git worktree, removed with
# `git worktree remove --force --force` (rm -rf if that fails) and pruned, so its
# branch and commits stay in the shared repo; anything else, rm -rf. An entry
# counts removed only when it is verifiably gone, else failed. freed_kb is the
# measured df Available delta on the root, 0 when unreadable. One log line per
# removed, busy or failed entry and one summary line go to
# <harness>/logs/pool-worktree-sweep.log.
set -uo pipefail

H="${HARNESS:-/data/harness}"
ROOT=""; PROC=/proc; KEEP=()
usage() { echo "usage: pool-worktree-sweep.sh --root <abs dir> [--keep <name>]... [--proc <dir>] [--harness <dir>]" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="${2:-}"; shift 2 ;;
    --keep)    KEEP+=("${2:-}"); shift 2 ;;
    --proc)    PROC="${2:-}"; shift 2 ;;
    --harness) H="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) usage; echo "WTSWEEP unreadable bad argument $1"; exit 2 ;;
  esac
done
LOG="$H/logs/pool-worktree-sweep.log"

[ -n "$ROOT" ] || { echo "WTSWEEP unreadable no --root"; exit 2; }
case "$ROOT" in /*) ;; *) echo "WTSWEEP unreadable root is not absolute: $ROOT"; exit 2 ;; esac
RROOT=$(readlink -f "$ROOT" 2>/dev/null || printf '%s' "$ROOT")
[ "$RROOT" != / ] || { echo "WTSWEEP unreadable root is /"; exit 2; }
[ -r "$PROC/self" ] || { echo "WTSWEEP unreadable no $PROC/self"; exit 2; }
[ -d "$RROOT" ] || { echo "WTSWEEP ok removed=0 busy=0 kept=0 failed=0 freed_kb=0"; exit 0; }

say_log() {
  mkdir -p "$H/logs" 2>/dev/null && printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null
  return 0
}
avail_kb() { df -Pk "$RROOT" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'; }

# Every live cwd, read once: "<pid> <resolved path>".
CWDS=()
for c in "$PROC"/[0-9]*/cwd; do
  t=$(readlink -f "$c" 2>/dev/null) || continue
  [ -n "$t" ] || continue
  p=${c%/cwd}; CWDS+=("${p##*/} $t")
done
busy_pid() { # busy_pid <path> -> prints the first pid whose cwd is <path> or under it
  local e
  for e in "${CWDS[@]+"${CWDS[@]}"}"; do
    case "${e#* }" in "$1"|"$1"/*) printf '%s\n' "${e%% *}"; return 0 ;; esac
  done
  return 1
}
kept() { local k; for k in "${KEEP[@]+"${KEEP[@]}"}"; do [ "$k" = "$1" ] && return 0; done; return 1; }

before=$(avail_kb)
removed=0; busy=0; nkept=0; failed=0
while IFS= read -r -d '' e; do
  n=${e##*/}
  if kept "$n"; then nkept=$((nkept+1)); continue; fi
  if pid=$(busy_pid "$e"); then busy=$((busy+1)); say_log "busy $n pid=$pid"; continue; fi
  how=rm
  if [ -L "$e" ]; then
    how=unlink; rm -f "$e" 2>/dev/null
  elif [ -f "$e/.git" ] && gd=$(sed -n 's/^gitdir: //p' "$e/.git" 2>/dev/null | head -1) \
       && [[ "$gd" == */.git/worktrees/* ]]; then
    how=worktree; repo=${gd%%/.git/worktrees/*}
    git -C "$repo" worktree remove --force --force "$e" >/dev/null 2>&1
    [ -e "$e" ] && rm -rf --one-file-system "$e" 2>/dev/null
    git -C "$repo" worktree prune >/dev/null 2>&1
  else
    rm -rf --one-file-system "$e" 2>/dev/null
  fi
  if [ ! -e "$e" ] && [ ! -L "$e" ]; then removed=$((removed+1)); say_log "removed $n ($how)"
  else failed=$((failed+1)); say_log "failed $n ($how): still present"; fi
done < <(find "$RROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)

after=$(avail_kb); freed=0
case "$before$after" in ''|*[!0-9]*) ;; *) [ "$after" -gt "$before" ] && freed=$((after - before)) ;; esac
line="WTSWEEP ok removed=$removed busy=$busy kept=$nkept failed=$failed freed_kb=$freed"
say_log "$line root=$RROOT"
echo "$line"
exit 0

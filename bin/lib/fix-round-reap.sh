# shellcheck shell=bash
# bin/lib/fix-round-reap.sh — BH-9906: what bin/fix-round-claim.sh uses to
# count its live runners and to clean up after a fix round. Sourced, never run.
# Defines functions only; nothing runs and nothing is written on source.
#
# WHY. GNU `timeout` signals only its own process group. A fix round runs its
# verification under nested `timeout ... npm ...` commands, and each of them is
# a process group of its own, so the outer kill missed them. The round's TERM
# trap then removed the worktree while vitest workers still ran in it (the
# ERR_MODULE_NOT_FOUND lines on project-3, 2026-11-23). The runner now starts the
# round in its own SESSION and sweeps every process of that session, and it
# removes the worktree only when no process has its cwd under it.
#
#   frr_lock_held <file>        rc 0 when a live process holds a lock on <file>.
#                               Read from /proc/locks (no lock is taken, so a
#                               runner that starts at that instant never sees
#                               its own lock as busy). /proc/locks unreadable:
#                               a `flock -n` probe. FRR_PROC_LOCKS overrides
#                               the path (tests).
#   frr_running <locks-dir>     prints the count of held fix-round-<p>-<ck>.lock
#                               files (two dashes at least, so the pass lock
#                               frc-claim-pass.lock and a one-dash name are not
#                               runners).
#   frr_session_sweep <sid> <grace>
#                               TERM to every process of session <sid> (the
#                               caller excepted), KILL to what is left after
#                               <grace> s, then wait up to <grace> s more until
#                               the session is empty. rc 0 empty, rc 1 a process
#                               is left (each one logged).
#   frr_cwd_pids <dir>          prints the pids whose cwd is <dir> or under it.
#   frr_wt_remove <wt> <grace>  KILL the processes with their cwd under <wt>,
#                               check again, then `git worktree remove --force`
#                               and an anchored rm -rf (only under
#                               $H/tmp/brfix/). A process still there: the tree
#                               is left, one line, rc 1 (bin/disk-clean.sh
#                               sweeps it later).
# Log: the caller's frc_log when it has one, else stderr.

_frr_log() { if command -v frc_log >/dev/null 2>&1; then frc_log "$*"; fi; printf 'fix-round-reap: %s\n' "$*" >&2; }

frr_lock_held() {
  local f="${1:-}" ino pl="${FRR_PROC_LOCKS:-/proc/locks}"
  [ -n "$f" ] && [ -e "$f" ] || return 1
  if [ -r "$pl" ] && ino=$(stat -c %i "$f" 2>/dev/null) && [ -n "$ino" ]; then
    # A line is "<n>: FLOCK ADVISORY WRITE <pid> <maj>:<min>:<inode> 0 EOF";
    # a waiter's line has "->" after the number and holds nothing.
    awk -v i="$ino" '$2 == "->" { next }
      { for (k = 1; k <= NF; k++) if ($k ~ /^[0-9a-f]+:[0-9a-f]+:[0-9]+$/) { n = split($k, a, ":"); if (a[n] == i) found = 1 } }
      END { exit !found }' "$pl" 2>/dev/null
    return
  fi
  ! flock -n "$f" true 2>/dev/null
}

frr_running() {
  local d="${1:-}" f n=0
  [ -d "$d" ] || { echo 0; return 0; }
  for f in "$d"/fix-round-*-*.lock; do
    [ -e "$f" ] || continue
    frr_lock_held "$f" && n=$((n + 1))
  done
  echo "$n"
}

# _frr_sid_pids <sid> — the pids of session <sid>, this shell excepted.
_frr_sid_pids() {
  ps -eo pid=,sid= 2>/dev/null | awk -v s="$1" -v me="$$" -v bp="${BASHPID:-$$}" '$2 == s && $1 != me && $1 != bp { print $1 }'
}

frr_session_sweep() {
  local sid="${1:-}" grace="${2:-60}" pids i
  case "$sid" in ''|*[!0-9]*) _frr_log "session sweep: no session id ('$sid'), nothing swept"; return 1 ;; esac
  case "$grace" in ''|*[!0-9]*) grace=60 ;; esac
  pids=$(_frr_sid_pids "$sid")
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  for (( i = 0; i < grace; i++ )); do
    pids=$(_frr_sid_pids "$sid"); [ -n "$pids" ] || return 0
    sleep 1
  done
  _frr_log "session $sid: $(printf '%s' "$pids" | wc -w) process(es) still alive ${grace}s after TERM, sending KILL: $(printf '%s' "$pids" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  for (( i = 0; i < grace; i++ )); do
    pids=$(_frr_sid_pids "$sid"); [ -n "$pids" ] || return 0
    sleep 1
  done
  _frr_log "session $sid: still alive after KILL: $(printf '%s' "$pids" | tr '\n' ' ')"
  return 1
}

frr_cwd_pids() {
  local d="${1%/}" c l pid
  [ -n "$d" ] || return 0
  for c in /proc/[0-9]*/cwd; do
    l=$(readlink "$c" 2>/dev/null) || continue
    case "$l" in "$d"|"$d"/*) pid="${c#/proc/}"; pid="${pid%/cwd}"; [ "$pid" = "$$" ] || echo "$pid" ;; esac
  done
}

frr_wt_remove() {
  # Root: ${HARNESS:-${H:-}} only (BH-2613). With no root the anchored rm is
  # skipped; git worktree remove still runs.
  local wt="${1%/}" grace="${2:-60}" pids i repo
  local H="${HARNESS:-${H:-}}"
  [ -n "$wt" ] || return 1
  [ -e "$wt" ] || return 0
  case "$grace" in ''|*[!0-9]*) grace=60 ;; esac
  pids=$(frr_cwd_pids "$wt")
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null
    for (( i = 0; i < grace; i++ )); do
      pids=$(frr_cwd_pids "$wt"); [ -n "$pids" ] || break
      sleep 1
    done
    if [ -n "$pids" ]; then
      _frr_log "worktree $wt left on disk: pid(s) $(printf '%s' "$pids" | tr '\n' ' ')still have their cwd under it (bin/disk-clean.sh sweeps it)"
      return 1
    fi
  fi
  repo=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && repo="${repo%/.git}"
  if [ -n "$repo" ] && [ -d "$repo" ]; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 \
      || git -C "$repo" worktree remove --force --force "$wt" >/dev/null 2>&1
  fi
  # The anchored remove: only a tree under the harness's own brfix scratch.
  if [ -n "$H" ]; then
    case "$wt" in "$H/tmp/brfix/"?*) [ -e "$wt" ] && rm -rf -- "$wt" ;; esac
  fi
  [ -n "$repo" ] && [ -d "$repo" ] && git -C "$repo" worktree prune >/dev/null 2>&1
  [ ! -e "$wt" ] || { _frr_log "worktree $wt could not be removed"; return 1; }
  return 0
}

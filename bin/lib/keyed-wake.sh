#!/bin/bash
# bin/lib/keyed-wake.sh — ring the merge conductor for ONE PR the moment
# something it waits on has happened, instead of leaving the PR to the next
# */5 cron tick. Sourced, never run.
#
# WHY IT EXISTS (Lane D, 2026-09-24). An approved, green, CLEAN PR waited for
# the conductor's next tick after every event the conductor itself caused: a
# detached re-review finishing APPROVE is read by a LATER tick, and that tick
# may be held by the project's cadence hold (mc_tick_secs) or land minutes
# later. GitHub's own events (pull_request, check_suite) already ring the
# conductor through bin/wake-loop.sh; a verdict the harness writes into its own
# ledger rings nobody. This is that doorbell for the hub-side verdicts.
#
# THE MECHANISM IS THE KEYED TICK THE CONDUCTOR ALREADY HAS (BH-1387):
# `MC_ONLY_PR=<owner/repo>#<n> bin/merge-conductor.sh` works only that PR, under
# that PR's own lock, and runs none of the fleet sweeps. The cron tick stays the
# backstop: a wake that is refused, deduped or lost costs one tick of latency,
# never a merge.
#
# BOUNDED. One launch per PR per MC_KEYED_WAKE_MIN_S (registry default 120s),
# stamped BEFORE the launch so two callers racing on one PR launch once.
# MC_KEYED_WAKE=0 turns it off and every caller behaves exactly as before.
# Knobs: catalog/lanes.d/merge-conductor.json (MC_KEYED_WAKE,
# MC_KEYED_WAKE_MIN_S). Tests: tests/merge-flow-lane-d-test.sh.

_kw_home() { printf '%s' "${MC_H:-${HARNESS:-/root/harness}}"; }

# kw_conductor <owner/repo> <num> <why> — rc 0 launched, 1 not launched (off,
# deduped, bad input, no conductor on this box). Never waits for the launch.
kw_conductor() {
  local slug="${1:-}" num="${2:-}" why="${3:-}" h dir stamp now last min script
  case "${MC_KEYED_WAKE:-1}" in 0) return 1 ;; esac
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  h=$(_kw_home); script="$h/bin/merge-conductor.sh"
  [ -x "$script" ] || return 1
  min="${MC_KEYED_WAKE_MIN_S:-}"; case "$min" in ''|*[!0-9]*) min=120 ;; esac
  dir="$h/state/merge-conductor/keyed-wake"; mkdir -p "$dir" 2>/dev/null || return 1
  stamp="$dir/${slug//\//_}#$num"
  # One stamp (and its lock file) per PR ever woken: a day-old one is past any
  # dedupe window, so it goes here rather than accumulating for ever. ONLY
  # under the directory lock held EXCLUSIVE, and skipped when it is busy (lead
  # MINOR 4 on #2215): `9>>` does not touch a lock file's mtime, so a day-old
  # .lock can be one a caller is sitting in flock on right now, and deleting it
  # hands the next caller a new inode. Every caller holds the directory lock
  # SHARED around its per-PR lock, so a prune never runs under one.
  ( flock -n 6 2>/dev/null || exit 0
    find "$dir" -maxdepth 1 -type f ! -name .prune.lock -mmin +1440 -delete 2>/dev/null
  ) 6>>"$dir/.prune.lock"
  now=$(date +%s)
  # Check-and-stamp under one flock: two callers on one PR launch once.
  (
    flock -s -w 5 6 2>/dev/null || exit 1
    exec 9>>"$stamp.lock" || exit 1
    flock -w 5 9 2>/dev/null || exit 1
    last=$(head -1 "$stamp" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge "$min" ] || exit 1
    printf '%s\n' "$now" > "$stamp" || exit 1
  ) 6>>"$dir/.prune.lock" || return 1
  # Detached, with every lock fd closed: a conductor that inherited a caller's
  # PR lock (fd 9) or merge lock (fd 8) would hold it for its whole life
  # (bin/lib/mc/locks.sh, the 03:54-04:02Z stall).
  # MC_FANIN_SOLO_RUN is set from KW_FANIN_SOLO on every launch, so a solo
  # run's own wakes of other PRs never inherit its marker (BH-4842). The
  # backstop's window (MC_WORKERS_DONE_BY, MC_WINDOW_DEFER_FILE) is cleared:
  # a detached run is not under that fire's `timeout`.
  # MC_PR_LOCK_WAIT_S is set from KW_PR_LOCK_WAIT_S on every launch, empty
  # unless the caller holds this PR's lock itself (mc_ready_rekick): then the
  # run waits for it instead of skipping (mc_pr_lock_take).
  ( MC_ONLY_PR="$slug#$num" WAKE_LAUNCH=1 MC_FANIN_SOLO_RUN="${KW_FANIN_SOLO:-}" MC_PR_LOCK_WAIT_S="${KW_PR_LOCK_WAIT_S-}" MC_WORKERS_DONE_BY= MC_WINDOW_DEFER_FILE= setsid "$script" </dev/null >/dev/null 2>&1 9>&- 8>&- 7>&- 6>&- & ) 2>/dev/null
  if command -v mc_log >/dev/null 2>&1; then
    mc_log "$slug#$num KEYED_WAKE: conductor launched for this PR now${why:+ ($why)} — the cron tick stays the backstop"
  fi
  return 0
}

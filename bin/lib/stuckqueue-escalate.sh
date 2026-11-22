#!/bin/bash
# bin/lib/stuckqueue-escalate.sh — BH-9818: the pipeline-health stuck-queue
# alert (check 1, "queued Nm with no spawn") goes to the operator channel ONE
# time after AFTER firings with no state change, and then it stops repeating.
# Sourced, never executed: functions only, nothing runs at source time.
#
# WHY. project-6-os, 2026-11-18: `ph-stuckqueue_project-6-os_MK-3788` fired 19
# times (`TK-3797` 13 times) on a queue file that never changed, and no one
# acted. A repeat that changes nothing is noise.
#
#   sqe_note <harness> <project> <queue-file> <ttl>  -> emit | escalate | quiet
#     bin/pipeline-health.sh, block `stuck queue`, before its alert() call.
#     Counter state/stuckqueue-escalate/<p>/<base>.n, one line
#     `<n> <sig> <last_epoch> <escalated 0|1>`; <sig> is `<mtime>:<size>` of
#     the queue file (no state change = the same sig). A call counts as a
#     firing only when <ttl> (the alert's own dedupe window) has passed since
#     the last one. Sig changed: n=1, emit. n < AFTER: emit. n reaches AFTER:
#     one bin/lane-alert.sh --severity critical message with the cause (the
#     BH-9818 park reason of the key, bin/lib/triage-repeat-park.sh), escalated=1
#     only after rc 0, print `escalate` (a failed send prints `emit` and tries
#     again on the next firing). Escalated: `quiet`. A counter that cannot be
#     written prints `emit` (the behaviour before this lib).
#   sqe_prune <harness> <project>
#     Deletes the counters whose queue file is gone.
#
# KNOB: STUCKQUEUE_ESCALATE_AFTER (catalog/lanes.d/pipeline-health.knobs.d/
# STUCKQUEUE_ESCALATE_AFTER.json, applied by lane_env_apply pipeline-health;
# the code fallback is 5, 0 = off: always emit).
# shellcheck shell=bash
if [ -n "${STUCKQUEUE_ESCALATE_LIB:-}" ]; then return 0 2>/dev/null; fi
STUCKQUEUE_ESCALATE_LIB=1

_sqe_after() {
  local a="${STUCKQUEUE_ESCALATE_AFTER:-5}"   # fallback names the knob row above
  case "$a" in ''|*[!0-9]*) a=5 ;; esac
  a=$((10#$a))
  [ "$a" -gt 100 ] && a=100
  printf '%s' "$a"
}

# _sqe_cause <harness> <project> <base> — the park reason of the key, else a
# plain "no record". A GitHub board parks under the issue number.
_sqe_cause() {
  local k r d="$1/state/triage-repeat/$2"
  for k in "$3" "$(printf '%s' "$3" | sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p')"; do
    [ -n "$k" ] || continue
    r=$(head -1 "$d/$k.park" 2>/dev/null | cut -f5)
    [ -n "$r" ] && { printf '%s' "$r" | cut -c1-200; return 0; }
  done
  printf 'no triage-repeat park record'
}

# _sqe_put <file> <n> <sig> <now> <escalated> — tmp + mv; rc 1 when not written.
_sqe_put() {
  mkdir -p "${1%/*}" 2>/dev/null && printf '%s %s %s %s\n' "$2" "$3" "$4" "$5" > "$1.tmp.$$" 2>/dev/null \
    && mv -f "$1.tmp.$$" "$1" 2>/dev/null && return 0
  rm -f "$1.tmp.$$" 2>/dev/null
  return 1
}

sqe_note() {
  local h="${1:-}" p="${2:-}" q="${3:-}" ttl="${4:-7200}" after now base f sig n s last esc age msg
  after=$(_sqe_after)
  [ "$after" -gt 0 ] && [ -n "$h" ] && [ -n "$p" ] && [ -f "$q" ] || { echo emit; return 0; }
  case "$ttl" in ''|*[!0-9]*) ttl=7200 ;; esac
  now="${NOW:-$(date +%s)}"
  base=$(basename "$q" .json)
  f="$h/state/stuckqueue-escalate/$p/$base.n"
  sig=$(stat -c '%Y:%s' "$q" 2>/dev/null) || { echo emit; return 0; }
  n=0; s=""; last=0; esc=0
  [ -r "$f" ] && read -r n s last esc < "$f" 2>/dev/null
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$esc" in 1) ;; *) esc=0 ;; esac
  if [ "$s" != "$sig" ]; then
    _sqe_put "$f" 1 "$sig" "$now" 0 || :
    echo emit; return 0
  fi
  # Inside the alert's own dedupe window: not a firing.
  if [ $(( now - last )) -lt "$ttl" ]; then
    if [ "$esc" = 1 ]; then echo quiet; else echo emit; fi
    return 0
  fi
  n=$((n + 1))
  if [ "$esc" = 1 ]; then
    _sqe_put "$f" "$n" "$sig" "$now" 1 || :
    echo quiet; return 0
  fi
  # The count is written BEFORE any send: a counter that cannot be written
  # must never send the operator message on every firing.
  _sqe_put "$f" "$n" "$sig" "$now" 0 || { echo emit; return 0; }
  [ "$n" -ge "$after" ] || { echo emit; return 0; }
  age=$(( (now - $(stat -c %Y "$q" 2>/dev/null || echo "$now")) / 60 ))
  msg="[pipeline-health] $p $base queued ${age}m with no spawn: fired $n times with no change. Cause: $(_sqe_cause "$h" "$p" "$base"). The repeat alert stops until the queue file changes."
  if "$h/bin/lane-alert.sh" --severity critical --id "ph-stuckqueue-escalate-$p-$base" pipeline-health "$msg" >/dev/null 2>&1 </dev/null; then
    _sqe_put "$f" "$n" "$sig" "$now" 1 || :
    echo escalate
  else
    echo emit
  fi
  return 0
}

sqe_prune() {
  local h="${1:-}" p="${2:-}" c b
  [ -n "$h" ] && [ -n "$p" ] || return 0
  for c in "$h/state/stuckqueue-escalate/$p/"*.n; do
    [ -f "$c" ] || continue
    b=${c##*/}; b=${b%.n}
    # Read only: keep the counter while its queue file exists.
    if [ -f "$h/state/build-queue/$p/$b.json" ]; then continue; fi
    rm -f "$c" 2>/dev/null
  done
  return 0
}

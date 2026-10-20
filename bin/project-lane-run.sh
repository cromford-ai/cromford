#!/bin/bash
# bin/project-lane-run.sh <lane> <project> <offset-secs> <cmd> [args...]
#
# One project's run of a lane, as bin/lib/project-lanes.sh pl_dispatch starts
# it (BH-5913). Sleeps the offset, takes locks/<lane>-<project>.lock on fd 9,
# creates state/<lane>/<project>, arms the project's GitHub credential, exports
# PL_LANE PL_PROJECT PL_SLUG PL_STATE_DIR PL_LOCK_FD, then runs
# `<cmd> [args...] <project>` with the lock held. The contract is in the
# library's header and docs/notes/2026-10-10-BH-5913-project-lanes.md.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
# shellcheck source=bin/lib/project-lanes.sh
. "$H/bin/lib/project-lanes.sh" || exit 1

[ "$#" -ge 4 ] || { echo "usage: project-lane-run.sh <lane> <project> <offset-secs> <cmd> [args...]" >&2; exit 2; }
lane="$1"; p="$2"; off="$3"; shift 3
pl_name_ok "$lane" && pl_name_ok "$p" || { echo "project-lane-run: bad lane or project name '$lane' '$p'" >&2; exit 2; }
case "$off" in ''|*[!0-9]*) off=0 ;; esac

# Close every inherited fd above 2: a lock the dispatcher's caller held must
# never travel into a run that lives for an hour. The shell's own xtrace fd
# (BASH_XTRACEFD, a traced CI shard's fd 199) stays: closing it sends the
# trace to stderr, into the lane's log.
for _fd in /proc/$$/fd/*; do
  _n="${_fd##*/}"
  case "$_n" in ''|*[!0-9]*) continue ;; esac
  [ "$_n" -gt 2 ] && [ "$_n" != 255 ] && [ "$_n" != "${BASH_XTRACEFD:-}" ] && eval "exec $_n>&-" 2>/dev/null
done
unset _fd _n

[ "$off" -gt 0 ] && sleep "$off"

# LOAD SHED (BH-7509): while state/hub-load/verdict says the hub is over
# hub_load.max_runnable, a SPAWNING lane (hls_lane_sheds: one that forks
# builds or agent sessions) starts no run. No lock is taken and the next
# dispatch tries again. A lane that only reads state runs as before. No
# verdict file or a stale one: no shed. hls_over runs first: it loads the
# verdict's lanes= list (HLS_LANES) that hls_lane_sheds checks (BH-7659).
# shellcheck source=bin/lib/hub-load-shed.sh
. "$H/bin/lib/hub-load-shed.sh" 2>/dev/null || hls_over() { return 1; }
if command -v hls_lane_sheds >/dev/null 2>&1 && hls_over "$H" && hls_lane_sheds "$lane"; then
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $lane: $HLS_LINE — this dispatch starts no run of $p"
  exit 0
fi

if ! pl_lock_take "$lane" "$p" 9; then
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $lane: a run of $p is still live (locks/$lane-$p.lock held) — this dispatch starts none"
  exit 0
fi
export PL_LANE="$lane" PL_PROJECT="$p" PL_LOCK_FD=9
export PL_STATE_DIR="$H/state/$lane/$p"
mkdir -p "$PL_STATE_DIR" 2>/dev/null
PL_SLUG=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || PL_SLUG=""
case "$PL_SLUG" in */*) ;; *) PL_SLUG="" ;; esac
export PL_SLUG
pl_token || true
exec "$@" "$p"

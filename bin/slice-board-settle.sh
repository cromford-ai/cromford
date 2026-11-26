#!/bin/bash
# bin/slice-board-settle.sh <project> <KEY> <pr-url> [record-dir|-] [--ticket <id>] [--park 0|1]
#
# File the remaining slices of a merged SLICE plan on an in-app product board
# (BH-8333). The CLI around slice_board_settle (bin/lib/slice-board.sh): the
# merge conductor spawns it detached after a board merge (bin/lib/mc/settle.sh),
# and a triage session runs it once for a SLICE result it closes out.
#
# --ticket is the master's board id (a cuid). Without it the plan's SLICE token
# is the id, and the board's answer must carry <KEY>. --park 1 (the default)
# lets the filer post the slice comment and move the master to in_progress;
# --park 0 files only, for a caller that posts its own comment.
#
# A plan with no `SLICE: C<k> of #` line still counts when it carries a weak
# slice marker (BH-10080: `SLICE: C0`, a SLICE-REASON line, `This plan builds
# slice C0`, or a `<KEY>: C0` PR title), and with no record and no merged spec
# the PR body is the plan (a hand-opened slice PR). A rest with no C<j> list is
# ONE "Rest of <KEY>" child from the plan's coverage rows, else the ticket's
# own scope. --park 1 posts one note on the master for unknown, exists and
# file-failed that says the rest is NOT filed (or where it is) and who files it.
#
# Prints the helper's word and exits with its rc:
#   0 filed:<keys> · 0 exists:<keys> (the master already has children; nothing
#   filed) · 1 deferred:<why> (rerun) · 2 unknown:<why> (paged; unknown:covered
#   = the plan maps every row to merged work) · 3 skip:<why> (not a slice of
#   this ticket, switched off, a dry run)
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$(cd "$(dirname "$0")" && pwd)/lib"
[ -r "$LIB/slice-board.sh" ] || LIB="$HARNESS/bin/lib"
usage() { echo "usage: $0 <project> <KEY> <pr-url> [record-dir|-] [--ticket <id>] [--park 0|1]" >&2; exit 64; }
POS=(); TICKET=""; PARK=1
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) [ $# -ge 2 ] || usage; TICKET="$2"; shift 2 ;;
    --park)   [ $# -ge 2 ] || usage; PARK="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) POS+=("$1"); shift ;;
  esac
done
[ "${#POS[@]}" -ge 3 ] && [ "${#POS[@]}" -le 4 ] || usage
case "$PARK" in 0|1) ;; *) usage ;; esac
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$LIB/gh-app-auth.sh" ] && . "$LIB/gh-app-auth.sh" 2>/dev/null
# shellcheck source=bin/lib/slice-board.sh
. "$LIB/slice-board.sh" || { echo "deferred:no-lib"; exit 1; }
rc=0
slice_board_settle "${POS[0]}" "${POS[1]}" "${POS[2]}" "${POS[3]:--}" "$TICKET" "$PARK" "$HARNESS" || rc=$?
exit "$rc"

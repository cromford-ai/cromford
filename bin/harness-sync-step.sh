#!/bin/bash
# bin/harness-sync-step.sh --step <name> --kind plain|deploy [--lock <file>]
#                          [--sha <sha40>] -- <cmd...>
# The runner of one DETACHED post-copy step of bin/harness-sync.sh (BH-7122):
# model-prices, docs-sync and console-pages. harness-sync puts it in front of
# the existing `timeout …` command inside the detached launch, so the step
# keeps its own timeout and gets the step line, the pending marker and the
# ALERT that the foreground steps get from hs_step (bin/lib/harness-sync-step.sh,
# which has the formats).
#
#   --lock   the lock the command takes with `flock -n … || exit 0`. When it is
#            busy the command is NOT run: a launch would exit 0 and clear a
#            marker whose deploy never happened. The line is `rc=busy secs=0`
#            and the marker stays as it is.
#   --sha    the sha the sync put live. A deploy marker is cleared only when
#            its sha is this one, so an older run that ends late never clears a
#            newer run's marker.
#
# Exit code: the command's rc (busy: 0). Without the lib it runs the command
# exactly as the launch did before this runner existed.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
STEP=""; KIND=plain; LOCK=""; SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step) STEP="${2:-}"; shift 2 ;;
    --kind) KIND="${2:-}"; shift 2 ;;
    --lock) LOCK="${2:-}"; shift 2 ;;
    --sha)  SHA="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) echo "harness-sync-step.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "harness-sync-step.sh: no command after --" >&2; exit 2; }
# shellcheck source=bin/lib/harness-sync-step.sh
. "$HARNESS/bin/lib/harness-sync-step.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/harness-sync-step.sh" 2>/dev/null \
  || exec "$@"
[ -n "$STEP" ] || exec "$@"

if [ -n "$LOCK" ] && [ -e "$LOCK" ] && ! flock -n "$LOCK" true 2>/dev/null; then
  hs_step_line "$STEP" busy 0
  exit 0
fi
T0=$(date +%s)
"$@"; RC=$?
hs_step_line "$STEP" "$RC" "$(( $(date +%s) - T0 ))"
[ "$KIND" = deploy ] && hs_pending_note "$STEP" "$RC" "$SHA"
exit "$RC"

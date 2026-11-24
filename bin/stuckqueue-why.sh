#!/bin/bash
# bin/stuckqueue-why.sh — BH-9863: name the gate that holds each queued key.
#
#   bin/stuckqueue-why.sh <project> <KEY>...
#
# One line per key: <KEY>\t<gate>\t<detail>\t<queue file age, or "no queue file">.
# The gate comes from bin/lib/stuckqueue-gate.sh (sqg_gate), the same local
# records the pipeline-health stuckqueue alert reads: the pool .held marker,
# the .dfs-wait line, the call-guard repeat park, a held build-key lock, the
# newest deferral record, then the pool and dispatch logs. 0 network calls.
# Run it on the hub, for example:
#   bin/stuckqueue-why.sh project-3 TK-767 TK-769 TK-773 TK-774 TK-779 TK-782
# rc 0 always; rc 2 on bad arguments.
set -uo pipefail
if [ $# -lt 2 ] || [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  echo "usage: bin/stuckqueue-why.sh <project> <KEY>..." >&2
  exit 2
fi
P="$1"; shift
case "$P" in *[!A-Za-z0-9._-]*) echo "stuckqueue-why: bad project '$P'" >&2; exit 2 ;; esac
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
# The tail size is the pipeline-health knob STUCKQUEUE_GATE_LOG_TAIL_KB, read
# from the environment only here (no settings read, so no network).
# shellcheck source=bin/lib/stuckqueue-gate.sh
. "$H/bin/lib/stuckqueue-gate.sh" || { echo "stuckqueue-why: cannot load bin/lib/stuckqueue-gate.sh" >&2; exit 2; }
NOW=$(date +%s)
for K in "$@"; do
  case "$K" in ''|*[!A-Za-z0-9._-]*) echo "stuckqueue-why: bad key '$K'" >&2; continue ;; esac
  G=$(sqg_gate "$H" "$P" "$K")
  # Read only: the queue file's mtime, with no variable that holds the path.
  A="no queue file"
  if M=$(stat -c %Y "$H/state/build-queue/$P/$K.json" 2>/dev/null); then A="queued $(( (NOW - M) / 60 ))m"; fi
  printf '%s\t%s\t%s\n' "$K" "$G" "$A"
done
exit 0

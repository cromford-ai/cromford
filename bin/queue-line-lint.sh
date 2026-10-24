#!/bin/bash
# bin/queue-line-lint.sh [file]
#   Print each live READY-QUEUE.log line that does not start with a ticket key.
#
# WHY IT EXISTS (BH-8262). Every reader of the queue keys on `^[A-Z]+-[0-9]`. A
# line a session wrote timestamp-first (project-3, 23 of 23 lines, TK-319 waited
# about 45 h) is a writer bug even after the readers learned to re-lead it.
# bin/queue-line-put.sh is the writer; this is the check that the file holds
# only what that writer writes. bin/decision-log.sh runs it after each triage
# session and logs the bad set once to logs/ready-queue.log.
#
# Default file: $HARNESS/logs/READY-QUEUE.log. Blank lines and `#` comment
# lines are not live and are skipped. Output, one per bad line:
#   NOT-KEY-FIRST <lineno>: <line>
# rc 0 none (or no file: prints `no queue file`), rc 1 one or more, rc 2 unreadable.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
F="${1:-$HARNESS/logs/READY-QUEUE.log}"
[ -e "$F" ] || { echo "no queue file"; exit 0; }
[ -r "$F" ] || { echo "queue-line-lint.sh: cannot read $F" >&2; exit 2; }
awk '
  /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
  !/^[A-Z]+-[0-9]/ { printf "NOT-KEY-FIRST %d: %s\n", NR, $0; bad = 1 }
  END { exit bad ? 1 : 0 }' "$F"

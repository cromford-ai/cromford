#!/bin/bash
# bin/queue-line-put.sh <project> <KEY> <ticket-id> <size> <kind> <reason...>
#   Write a ticket's line into logs/READY-QUEUE.log in the one shape every
#   reader parses, atomically, and mirror it as a `ready` build_queue row.
#
# WHY IT EXISTS (BH-8262). Triage sessions appended free-form lines by hand. On
# the project-3 box 23 of 23 lines were timestamp-first, every reader kept only
# `^[A-Z]+-[0-9]`, and TK-319 waited about 45 h. The readers now re-lead such a
# line (bin/lib/ready-queue.sh:_rq_norm); this is the writer side, so a session
# never composes the line itself. The line it writes:
#   <KEY> <ticket-id> size=<S|M|L|XL> kind=<bug|feature|copy|migration|infra> :: <reason> project=<p>
#
# ONE LINE PER KEY. A key with no line is appended (`>>` works on a +a file); a
# key whose line differs is replaced (all `^<KEY> ` lines go, the new one is
# appended); the exact line already there is left alone. The replace is a `mv`,
# so it takes the sidecar lock FIRST and locks/harden-state.lock second, the
# same order as bin/queue-line-drop.sh, and releases/re-arms the +a flag.
#
# rc 0 written / unchanged / replaced (one stdout line says which, printed only
#      after the file write returned 0)
# rc 1 lock timeout or write failure (file untouched; no row)
# rc 2 a bad argument (no lock taken, file untouched, no row; stderr names it)
# The row mirror runs after both locks are released, in a subshell, and never
# changes rc: the file is the delivery, the row is the copy.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
HERE="$(dirname "$0")"
Q="$HARNESS/logs/READY-QUEUE.log"

die2() { echo "queue-line-put.sh: $1" >&2; exit 2; }
[ $# -ge 5 ] || die2 "usage: queue-line-put.sh <project> <KEY> <ticket-id> <S|M|L|XL> <bug|feature|copy|migration|infra> <reason...> (reason is missing)"
P="$1"; KEY="$2"; TID="$3"; SIZE="$4"; KIND="$5"; shift 5
REASON=$(printf '%s' "$*" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ //; s/ $//')

# The consumers grep `project=[a-z-]+`; no fleet project has a digit.
[[ "$P" =~ ^[a-z][a-z-]*[a-z]$ ]] || die2 "refusing project '$P' (want lowercase letters and dashes, e.g. project-3)"
[[ "$KEY" =~ ^[A-Z]+-[0-9]+$ ]] || die2 "refusing key '$KEY' (not a ticket key: want e.g. TK-319)"
case "$TID" in ''|*[[:space:]]*|*=*) die2 "refusing ticket-id '$TID' (want one word with no '='; use - for none)" ;; esac
case "$SIZE" in S|M|L|XL) ;; *) die2 "refusing size '$SIZE' (want S, M, L or XL)" ;; esac
case "$KIND" in bug|feature|copy|migration|infra) ;; *) die2 "refusing kind '$KIND' (want bug, feature, copy, migration or infra)" ;; esac
[ -n "$REASON" ] || die2 "refusing an empty reason"
# A second project= token would make _rq_scope read the wrong project.
[[ " $REASON " == *" project="* ]] && die2 "refusing a reason that carries its own project= token"

LINE="$KEY $TID size=$SIZE kind=$KIND :: $REASON project=$P"

# >>> lib env (BH-7945) — the lock wait is a settings row; LANE_GATE_DISABLE=1
# (tests) skips the lookup. Fail-open: no lib, no row, the fallback below.
if [ "${LANE_GATE_DISABLE:-0}" != 1 ] && [ -r "$HERE/lib/lane-gate.sh" ]; then
  # shellcheck source=bin/lib/lane-gate.sh
  { . "$HERE/lib/lane-gate.sh" && command -v lib_env_apply >/dev/null && lib_env_apply queue-line-put; } >/dev/null 2>&1 || true
fi
# <<< lib env
# Fallback 30 s = settings row lib.queue-line-put.queue_line_put_lock_s
# (catalog/lanes.d/_lib.queue-line-put.json), the wait queue-line-drop.sh uses.
LOCK_S="${QUEUE_LINE_PUT_LOCK_S:-30}"
case "$LOCK_S" in ''|*[!0-9]*) LOCK_S=30 ;; esac

mkdir -p "$HARNESS/logs" 2>/dev/null
# The lock is a SIDECAR file, never the queue: the replace below swaps inodes.
exec 9>"$Q.lock" || exit 1
flock -w "$LOCK_S" 9 || { echo "queue-line-put.sh: could not lock $Q.lock within ${LOCK_S}s" >&2; exit 1; }

N=0
[ -f "$Q" ] && N=$(grep -c "^${KEY}[[:space:]]" "$Q" 2>/dev/null || true)
: "${N:=0}"
if [ "$N" = 1 ] && grep -qxF "$LINE" "$Q"; then
  ACT=unchanged
elif [ "$N" = 0 ]; then
  # A last line with no newline would glue this line onto it.
  NL=""
  [ -s "$Q" ] && [ -n "$(tail -c1 "$Q")" ] && NL=$'\n'
  printf '%s%s\n' "$NL" "$LINE" >> "$Q" || { echo "queue-line-put.sh: could not append to $Q" >&2; exit 1; }
  ACT=queued
else
  mkdir -p "$HARNESS/locks" 2>/dev/null
  exec 8>"$HARNESS/locks/harden-state.lock" || exit 1
  flock -w "$LOCK_S" 8 || { echo "queue-line-put.sh: could not lock harden-state.lock within ${LOCK_S}s" >&2; exit 1; }
  HS="$HERE/harden-state.sh"
  TMP="$Q.put.$$"
  grep -v "^${KEY}[[:space:]]" "$Q" > "$TMP"; GRC=$?
  # grep -v is rc 1 when every line went; rc 2 is a read error.
  [ "$GRC" -le 1 ] || { rm -f "$TMP"; echo "queue-line-put.sh: could not read $Q" >&2; exit 1; }
  printf '%s\n' "$LINE" >> "$TMP" || { rm -f "$TMP"; exit 1; }
  [ -x "$HS" ] && "$HS" --release "$Q"
  mv -f "$TMP" "$Q"; MVRC=$?
  # Unconditional, as in queue-line-drop.sh: the mv made a new inode with no flag.
  [ -x "$HS" ] && "$HS" --rearm "$Q"
  [ "$MVRC" -eq 0 ] || { rm -f "$TMP"; echo "queue-line-put.sh: could not replace $Q" >&2; exit 1; }
  ACT=replaced
fi

# Both locks go before the row call, so no triager waits on a network round trip.
exec 8>&- 9>&-
# A SUBSHELL for the same reason as queue-line-drop.sh: the lib sources the jobs
# client, whose shim can `exit 1` on a half-synced bin/.
# shellcheck source=bin/lib/ready-queue.sh
( [ -r "$HERE/lib/ready-queue.sh" ] && . "$HERE/lib/ready-queue.sh" 2>/dev/null
  command -v rq_put >/dev/null 2>&1 && rq_put "$HARNESS" "$P" "$KEY" "$TID" "$LINE" ) >/dev/null 2>&1
echo "$ACT $LINE"
exit 0

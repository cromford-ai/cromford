#!/bin/bash
# bin/queue-line-drop.sh <KEY> [<KEY>...]
#   Remove a ticket's line(s) from logs/READY-QUEUE.log, atomically.
#
# WHY IT EXISTS (the operator, 2026-09-14, parallel triagers). Consuming a queue line has
# always been "rewrite the file without it", and while ONE triage session per
# project owned the whole tick that was safe by construction. It no longer is:
# bin/run-triage.sh now dispatches one session per ticket key and several of them
# run at once, on one box, against one box-global READY-QUEUE.log. Two sessions
# that each read the file, drop their own line and write it back lose one of the
# two edits — and the line that survives is a ticket that was already built,
# while the one that vanished is a ticket nobody will launch.
#
# So the read-modify-write happens HERE, once, under the file's own sidecar lock,
# and the shard prompt tells the session to call this rather than rewrite the
# file itself. Not a new queue format — the same file, the same lines, the same
# `^<KEY> ` convention every prompt already uses.
#
# Idempotent and quiet: a key with no line is rc 0 and "dropped 0". Prints one
# line saying what went, so a session can put it in its board comment.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
Q="$HARNESS/logs/READY-QUEUE.log"
[ $# -gt 0 ] || { echo "usage: queue-line-drop.sh <KEY> [<KEY>...]" >&2; exit 2; }

# >>> ready row drop (BH-1033)
# A consumed line is a `ready` build_queue row that is no longer ready. A
# FUNCTION because it runs on BOTH exits: the normal one at the bottom, and the
# no-queue-file one immediately below. A box whose logs/READY-QUEUE.log does not
# exist yet is exactly the case this slice exists for — the ssh append that
# would have created the file is the thing that failed, so the row IS the queue
# — and returning before the row drop would leave a `ready` row for a key the
# session has already consumed: rq_any keeps answering "there is work", the
# fingerprint never changes, and the 4-hour ceiling in bin/triage-gate.sh buys a
# paid tick per project for a ticket nobody will launch, until some later build
# enqueue promotes the row out of `ready`.
# Keys are re-validated here because the loop below (which exits 2 on a bad key)
# has not run on the no-file path.
# Always quiet, always rc 0 — the worker refuses a row that is already `claimed`
# (a live build keeps it), a key with no row is the common case, and an outage
# is one log line in logs/ready-queue.log.
rq_drop_keys() {
  local k ok=()
  for k in "$@"; do
    case "$k" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    ok+=("$k")
  done
  [ ${#ok[@]} -gt 0 ] || return 0
  # A SUBSHELL, because the lib sources bin/jobs-client.sh and the BH-1194 shim
  # `exit 1`s when bin/lib/jobs/ is not beside it (a half-synced bin/). Taken in
  # this shell that exit is the SCRIPT's: it lands after the durable file
  # rewrite and before the "dropped N line(s)" line, so the triage shard that
  # called us reads rc 1 and no output for work that already succeeded. Inside
  # the subshell it costs the row half only, which is this function's whole
  # contract anyway — always quiet, always rc 0.
  # shellcheck source=bin/lib/ready-queue.sh
  ( [ -r "$(dirname "$0")/lib/ready-queue.sh" ] && . "$(dirname "$0")/lib/ready-queue.sh" 2>/dev/null
    command -v rq_drop >/dev/null 2>&1 && rq_drop "$HARNESS" "" "${ok[@]}" )
  return 0
}
# <<< ready row drop

[ -f "$Q" ] || { rq_drop_keys "$@"; echo "dropped 0 (no queue file)"; exit 0; }

# The lock is a SIDECAR file, never the queue itself: the rewrite below replaces
# the queue's inode, and a waiter holding a descriptor on the old one would take
# a lock on a file that no longer exists and edit an orphan.
exec 9>"$Q.lock" || exit 1
flock -w 30 9 || { echo "queue-line-drop.sh: could not lock $Q.lock within 30s" >&2; exit 1; }

# READY-QUEUE.log is an append-only (+a) ledger once bin/harden-state.sh has
# armed the box, and the rewrite below is a `mv` — rename over an append-only
# file is EPERM, so without this the queue would simply stop being consumed.
# Sidecar lock FIRST (above), then harden-state.lock, which is the only lock the
# arm-all lane takes: that order cannot invert. The critical section is the
# release/mv/rearm triple, milliseconds.
mkdir -p "$HARNESS/locks" 2>/dev/null
exec 8>"$HARNESS/locks/harden-state.lock" || exit 1
flock -w 30 8 || { echo "queue-line-drop.sh: could not lock harden-state.lock within 30s" >&2; exit 1; }
# Same dir as this script, so a scratch-$HARNESS test that copied only this file
# finds nothing, the [ -x ] guard is false, and the wrap is a no-op.
HS="$(dirname "$0")/harden-state.sh"

# grep -c exits 1 when the count is 0. Do not `|| echo 0` — that appends a
# second 0 and $((BEFORE - AFTER)) dies with an arithmetic syntax error.
BEFORE=$(grep -c . "$Q" 2>/dev/null || true)
: "${BEFORE:=0}"
TMP="$Q.drop.$$"
cp "$Q" "$TMP" || exit 1
for K in "$@"; do
  case "$K" in
    ''|*[!A-Za-z0-9._-]*) echo "queue-line-drop.sh: refusing key '$K' (not a ticket key)" >&2; rm -f "$TMP"; exit 2 ;;
  esac
  # A key-first line `^K<space>`, AND a timestamp-first line whose first
  # [A-Z]+-[0-9]+ token is K: bin/lib/ready-queue.sh _rq_norm makes those live
  # (#8257), so they must be droppable too, or a shipped ticket's line keeps
  # buying a paid queue-pending session forever (lead review #8257, BLOCK money).
  awk -v k="$K" '
    index($0, k" ") == 1 || index($0, k"\t") == 1 { next }
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ]/ {
      l = $0; sub(/^[^ ]* +/, "", l)
      if (match(l, /[A-Z]+-[0-9]+/) && substr(l, RSTART, RLENGTH) == k) next
    }
    { print }' "$TMP" > "$TMP.n" 2>/dev/null; mv -f "$TMP.n" "$TMP"
done
[ -x "$HS" ] && "$HS" --release "$Q"
mv -f "$TMP" "$Q"; MVRC=$?
# Unconditional: the mv produced a NEW inode with no flag, and on the failure
# path the old inode may already have been released. A file left writable is
# what the re-arm lane fixes within minutes; a queue line that vanished is not
# fixable at all.
[ -x "$HS" ] && "$HS" --rearm "$Q"
[ "$MVRC" -eq 0 ] || exit 1
AFTER=$(grep -c . "$Q" 2>/dev/null || true)
: "${AFTER:=0}"
# >>> ready row drop (BH-1033)
# AFTER the file rewrite, and with BOTH LOCKS EXPLICITLY RELEASED FIRST — a
# flock held on an open descriptor lives until the process exits, so without
# these two closes this would hold the queue's sidecar lock and
# harden-state.lock across a network call while other triagers wait on a
# rename. The file edit is already durable; this is the second, slower copy.
exec 8>&- 9>&-
rq_drop_keys "$@"
# <<< ready row drop
echo "dropped $((BEFORE - AFTER)) line(s) for: $*"
exit 0

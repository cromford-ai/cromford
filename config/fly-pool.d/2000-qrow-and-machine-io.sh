# <<< pool terminal / spawn cap / hold gate
QROW() { # QROW done|failed|requeue <key> <reason> [attempt] [meta] [ticket-id]
  # rc 1 ONLY from `requeue`, when an operator ABANDONED the ticket (BH-2406):
  # the row is closed and nothing is enqueued, so a caller must not write the
  # queue file or a line claiming a requeue. Every other path answers 0.
  command -v queue_done >/dev/null 2>&1 || return 0
  local _qr_jid
  case "$1" in
    # A requeue is CLOSE-THEN-ENQUEUE, not a status flip: enqueueing over a row
    # that is still `claimed` is a duplicate by design (that guard is what stops
    # a key being re-queued mid-build), so the dead attempt has to be closed
    # first. The worker then treats the re-queue of a terminal row as what it
    # is — a real new attempt, carrying the count forward.
    requeue) queue_done "$P" "$2" failed "$3" >/dev/null 2>&1 || true
             # AN ABANDONED TICKET IS FINAL (BH-2406). The operator ended the
             # ticket's newest build row, so this death or deferral is the end of
             # it, not a reason to spawn again. The row stays FAILED under a
             # reason br_from_queue never reads as a park (no `died N times`,
             # no `deferred N times`). rc 1/2 (not abandoned, or the worker did
             # not answer) is today's requeue, byte for byte.
             if command -v job_ticket_abandoned >/dev/null 2>&1 \
                && _qr_jid=$(job_ticket_abandoned "$P" "$2" 2>/dev/null); then
               queue_done "$P" "$2" failed "ABANDONED by an operator (job $_qr_jid): the pool does not requeue it" >/dev/null 2>&1 || true
               say "$2: job $_qr_jid was abandoned by an operator — row FAILED, not requeued"
               return 1
             fi
             # THE TICKET ID RIDES THE REQUEUE (2026-09-14). It used to be sent
             # empty, and the handoff below quarantines exactly that row
             # ("malformed queue entry (ticket='')") — so the retry this was
             # meant to buy was a machine that could never build. No id, no
             # enqueue: the row stays FAILED and bin/blocked-resolver.sh, which
             # can look the id up, owns the retry.
             if [ -z "${6:-}" ] || [ "${6:-}" = null ]; then
               HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $2: requeue has no ticket id — the row is left FAILED rather than enqueued blank; bin/blocked-resolver.sh owns the retry"
               return 0
             fi
             queue_put  "$P" "$2" "$6" fly "${4:-}" "${5:-}" >/dev/null 2>&1 || true ;;
    *)       queue_done "$P" "$2" "$1" "$3" >/dev/null 2>&1 || true ;;
  esac
  return 0
}


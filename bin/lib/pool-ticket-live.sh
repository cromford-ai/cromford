# shellcheck shell=bash
# bin/lib/pool-ticket-live.sh — BH-9922 scope 4: is a queued row's board ticket
# still live?
#
# WHY. On 2026-11-23 at 20:01Z the pool released TK-810 ("TK-776 is done") and
# spawned machine 0803426fd77048 for it. The owner archived TK-810 on the project-3
# board at 15:20Z. The queue row from 2026-11-22 was still `queued`, and no
# gate read the board: pool_hold_check answers `clear board ticket` with no
# read (bin/fly-pool.sh), because the HOLD gate reads GitHub issues only.
#
# Sourced, never executed. Functions only; safe under `set -u`.
#
#   ptl_read <harness> <project> <ticket-id>
#     Prints one class and sets PTL_CLASS (and PTL_STATUS, the board's status):
#       live        the ticket is open on the board, or it is not a board
#                   ticket (a GitHub-Issues ticket is not read: the HOLD gate
#                   already parks closed and label-absent rows on every spawn)
#       archived    status `archived`, or `archivedAt` set, or `archived` /
#                   `isArchived` true
#       done        status done | closed | cancelled | canceled
#       paused      status paused | on_hold | on-hold | hold
#       not-found   the ticket GET answered 404 AND a GET of the project's
#                   /boards answered 2xx in the same call (the contract
#                   answers 404 on a bad token too, so a 404 alone is not
#                   proof)
#       unreadable  anything else: no context, a timeout, a 5xx, a body that
#                   is not a ticket. A caller never drops a row on it.
#     rc 0 always. One answer per (project, ticket) per process (_PTL_CACHE).
#   ptl_terminal <class>   rc 0 for archived | done | paused | not-found.
#
# READS. Only through the tracker board seam (bin/lib/tracker.sh
# tracker_context, bin/lib/tracker/board.sh trk_board_ticket_raw and
# trk_board_boards_raw). No other network.
#
# TEST SEAM. POOL_TICKET_LIVE_FILE is a TSV `<project>\t<ticket>\t<class>`.
# With it set, no read is made: a matching row answers, and no row is
# `unreadable`.

PTL_CLASS=""; PTL_STATUS=""
declare -gA _PTL_CACHE=()

ptl_terminal() { case "${1:-}" in archived|done|paused|not-found) return 0 ;; esac; return 1; }

# ptl_classify — stdin is one ticket GET body; prints the class.
ptl_classify() {
  jq -r '(.ticket // .) as $t
    | if ($t | type) != "object" or (($t | has("id")) | not) then "unreadable"
      else (($t.status // "") | tostring | ascii_downcase) as $s
      | if $s == "archived" or (($t.archivedAt // null) != null and ($t.archivedAt // "") != "")
           or $t.archived == true or $t.isArchived == true then "archived"
        elif (["done","closed","cancelled","canceled"] | index($s)) != null then "done"
        elif (["paused","on_hold","on-hold","hold"] | index($s)) != null then "paused"
        else "live" end
      end' 2>/dev/null || echo unreadable
}

# _ptl_board <ticket> — the board read, in this shell. Sets PTL_CLASS.
_ptl_board() {
  local id="$1" err raw rc=0
  # Tickets are path segments; anything else is never sent.
  [[ "$id" =~ ^[A-Za-z0-9_.:-]+$ ]] || { PTL_CLASS=unreadable; return 0; }
  err=$(mktemp "${TMPDIR:-/tmp}/ptl-err.XXXXXX" 2>/dev/null) || { PTL_CLASS=unreadable; return 0; }
  raw=$(TRK_ERR="$err" TRK_DRY=0 trk_board_ticket_raw "$id") || rc=$?
  if [ "$rc" = 0 ]; then
    PTL_CLASS=$(ptl_classify <<<"$raw")
    PTL_STATUS=$(jq -r '(.ticket // .).status // "" | tostring' 2>/dev/null <<<"$raw")
  elif [ "$rc" = 22 ] && grep -q 'error: 404' "$err" 2>/dev/null \
       && declare -F trk_board_boards_raw >/dev/null 2>&1 \
       && TRK_ERR=/dev/null trk_board_boards_raw >/dev/null; then
    PTL_CLASS=not-found
  else
    PTL_CLASS=unreadable
  fi
  rm -f "$err"
  return 0
}

ptl_read() {
  local root="${1:-}" p="${2:-}" t="${3:-}" ck kind s i c
  PTL_CLASS=unreadable; PTL_STATUS=""
  ck="$p/$t"
  if [ -n "${_PTL_CACHE[$ck]:-}" ]; then PTL_CLASS="${_PTL_CACHE[$ck]}"; printf '%s\n' "$PTL_CLASS"; return 0; fi
  if [ -n "${POOL_TICKET_LIVE_FILE:-}" ]; then
    while IFS=$'\t' read -r s i c; do
      [ "$s" = "$p" ] && [ "$i" = "$t" ] && { PTL_CLASS="$c"; break; }
    done < "$POOL_TICKET_LIVE_FILE"
  elif [ -n "$root" ] && [ -n "$p" ] && [ -n "$t" ]; then
    if ! declare -F tracker_context >/dev/null 2>&1; then
      # shellcheck source=bin/lib/tracker.sh
      . "$root/bin/lib/tracker.sh" 2>/dev/null || . "${BASH_SOURCE[0]%/*}/tracker.sh" 2>/dev/null || :
    fi
    if declare -F tracker_adapter >/dev/null 2>&1 && kind=$(HARNESS="$root" tracker_adapter "$p" 2>/dev/null); then
      if [ "$kind" != board ]; then
        PTL_CLASS=live
      elif HARNESS="$root" tracker_context "$p" fly-pool >/dev/null 2>&1 && declare -F trk_board_ticket_raw >/dev/null 2>&1; then
        _ptl_board "$t"
      fi
    fi
  fi
  case "$PTL_CLASS" in live|archived|done|paused|not-found|unreadable) ;; *) PTL_CLASS=unreadable ;; esac
  _PTL_CACHE[$ck]="$PTL_CLASS"
  printf '%s\n' "$PTL_CLASS"
  return 0
}

# pool_ticket_live_gate <job-file> <key> <ticket-id> <release|spawn> — BH-9922:
# rc 1 when the board ticket is archived, done, paused or not found
# (ptl_read, above). Called by bin/fly-pool.sh, whose QROW, say,
# pool_hold_clear, HARNESS and P it uses. The row is then FAILED with that
# reason, its queue file removed, its hold marker and its after-since wait
# clock (the file and the pool-state marker) cleared, and no machine starts. `release` always reads; `spawn` reads only a row whose
# .enqueued_at is at least POOL_TICKET_LIVE_AGE_S old. A read that does not
# answer is one line and rc 0: the row goes on as before.
pool_ticket_live_gate() {
  local jf="$1" k="$2" t="$3" when="$4" lim ts at cls
  command -v ptl_read >/dev/null 2>&1 && [ -n "$t" ] || return 0
  if [ "$when" = spawn ]; then
    # POOL_TICKET_LIVE_AGE_S: catalog/lanes.d/fly-pool.knobs.d/POOL_TICKET_LIVE_AGE_S.json; 21600 is its fallback.
    lim="${POOL_TICKET_LIVE_AGE_S:-21600}"; case "$lim" in ''|*[!0-9]*) lim=21600 ;; esac
    ts=$(jq -r '.enqueued_at // empty' "$jf" 2>/dev/null)
    [ -n "$ts" ] && at=$(date -u -d "$ts" +%s 2>/dev/null) || return 0
    [ $(( $(date -u +%s) - at )) -ge "$lim" ] || return 0
  fi
  ptl_read "$HARNESS" "$P" "$t" >/dev/null; cls="$PTL_CLASS"
  if command -v ptl_terminal >/dev/null 2>&1 && ptl_terminal "$cls"; then
    QROW failed "$k" "ticket $t is $cls on the board — pool row dropped, no machine"
    rm -f "$jf"
    pool_hold_clear "$k" || true
    # The wait clock goes with the row: a later enqueue of this key starts a
    # fresh clock, not this one (which would hit POOL_AFTER_MAX_MIN at once).
    [ -n "${PDIR:-}" ] && rm -f "$PDIR/$k.after-since"
    command -v psr_marker_clear >/dev/null 2>&1 && { psr_marker_clear "$P" "$k" after-since || true; }
    say "DROPPED $k: ticket $t is $cls on the board — pool row dropped, no machine"
    return 1
  fi
  [ "$cls" = unreadable ] && say "$k: the board read of ticket $t did not answer (before a $when) — the row goes on as before"
  return 0
}

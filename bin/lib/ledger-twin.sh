#!/bin/bash
# bin/lib/ledger-twin.sh — BH-1036. The row twin of a file marker, for the lanes
# whose file store is today the ONLY record that paid or client-visible work
# already happened. Sourced, never executed.
#
# WHY IT EXISTS. Six hub/box file stores answer "have we already paid for
# this?" — a review, its daily cap, a resolution session, a train close-out, a
# browser drive, a plan session. All six live in state/ on ONE machine. A hub
# wipe, or the same work re-offered to a different pool box, and every one of
# them says "never seen it": the money is spent twice and the client is
# commented on twice. The fix is not a new store — the `ledgers` table (PK
# `(kind, key)`, verbs `job_ledger_get` / `job_ledger_put` in
# bin/jobs-client.sh) already carries exactly this shape for pr_merged and
# plan_malformed. This library is the small adapter every lane uses so that
# all six read and write it the same way.
#
# THE SEVENTH STORE IS ALREADY DONE, ELSEWHERE, AND IS NOT HERE (r1 B1).
# bin/check-migration-prs.sh's "alert once per migration PR" moved to
# `ledgers(kind=migration)` under BH-1040, with its own three-way read and a
# deliberate WRITE-AFTER-SEND (the row is stamped once beat.sh has returned).
# A twin of it under a second kind would be a fact two dedups could not see,
# with two different write orders — so that lane keeps BH-1040's store and this
# library does not carry a `migration_pr_alerted` kind.
#
# THE FILE IS STILL THE CACHE, FOR ONE CYCLE (the epic's rule). Every lane
# writes its file FIRST and its row second, and reads the file first, asking the
# row only when the file has nothing. So a ledger outage costs nothing and the
# cycle that deletes the file reads is a later slice. bin/review-autopilot.sh
# took that slice (BH-4156): with the flag up its rows are the record (lt_row
# and lt_put_rc, at the end of this file). It writes a file only as a local
# cache: a body over LT_DETAIL_MAX, or a row write that failed until it lands.
#
# IT SHIPS DARK. Nothing here does anything until the `no-twin-ledgers` pause
# flag is up — the DB row, materialised on each box as `flags/no-twin-ledgers` by
# the existing flag_active reconcile. With the row absent every lane is
# byte-for-byte what it is today, including making no request at all.
#
#   bin/jobs-client.sh flag-set no-twin-ledgers on "BH-1036 cycle 1"
#
# THE KINDS AND THEIR KEYS (the key is always the identity the FILENAME encoded,
# so the two halves can never disagree about what "this one" means):
#
#   review_autopilot      <owner/repo>#<num>@<head12>   the head's state word
#                         (reviewed | skipped | reviewed-unposted | empty |
#                         failed | *-terminal); detail = the WHOLE record text
#                         (BH-4156: the first line the key file held, plus its
#                         sha= lines). A row written before BH-4156 holds only
#                         reviewed | skipped with a short detail.
#   review_autopilot_body <owner/repo>#<num>@<head12>   cached | dropped; detail =
#                         the paid-for, unposted review comment (BH-4156)
#   review_autopilot_pr   <owner/repo>#<num>            reviewed; detail = the
#                         head12, then the newest `reviewed` record (BH-4156,
#                         for the verdict replay)
#   review_autopilot_cap  <project> <YYYYMMDD>          the count, as text
#   lander                <project>#<num>@<head>        attempted
#   batch_member          <owner/repo>#<num>@<head>     landed | red | abandoned
#   postmerge_qa          <build-dir basename>          PASS | FAIL | NOT_COVERED_NO_QA_ENV
#   plan_malformed        <project> <KEY>               requeued | held | skipped | released
#   triage_gate           <project>                     <sha256 of gate.json> <gate-meta epoch>
#   triage_gate           <project> fail                <sha16|none> <n> | cleared
#     (BH-2318, bin/lib/triage-gate-ledger.sh: the triage gate's state/<p>.gate.*
#      files; the key is the project because the filenames are keyed by it)
#
# FAIL-OPEN, IN BOTH DIRECTIONS, and the asymmetry is deliberate:
#   - a READ that cannot be answered (flag off, no client, worker down) is rc 1
#     and NEVER "already done" — the lane falls back to its file and, at worst,
#     does the work a second time. Reading an outage as done drops work silently.
#   - a WRITE that cannot be made is rc 0 — the file line is already on disk, so
#     a lane must not fail because the side channel blinked.
#   - and either one, once, latches the library off for the rest of the process
#     (see the breaker below) so a HANGING worker cannot be paid for per
#     candidate.
#
# Every function is a no-op when bin/jobs-client.sh was not sourced: a tree
# without the client is today's tree, and this library is copied into scratch
# fixtures on its own.

# The harness root, in the two spellings the callers use. bin/lander.sh,
# bin/run-build.sh and bin/batch-resolve.sh bind HARNESS;
# bin/review-autopilot.sh and bin/postmerge-qa.sh bind H.
_lt_harness() { printf '%s' "${HARNESS:-${H:-/root/harness}}"; }

# ONE RESOLUTION PER PROCESS. flag_active reconciles the file from the DB on
# every call, and the candidate loops below it (one per open PR, one per train
# candidate) would turn that into a request per row for an answer that cannot
# change inside a single lane run. The cache is per process, so a flag flip is
# picked up by the next tick — which is the same latency the file itself has.
_LT_ON=""
lt_on() { # rc 0 when the no-twin-ledgers flag is up
  [ -z "$_LT_ON" ] || { [ "$_LT_ON" = 1 ]; return; }
  if declare -F flag_active >/dev/null 2>&1; then
    if flag_active no-twin-ledgers; then _LT_ON=1; else _LT_ON=0; fi
  elif [ -f "$(_lt_harness)/flags/no-twin-ledgers" ]; then
    _LT_ON=1
  else
    _LT_ON=0
  fi
  [ "$_LT_ON" = 1 ]
}

# ONE OUTAGE PER PROCESS IS ENOUGH (r1 I3). A worker that REFUSES is cheap — the
# client returns at once. A worker that HANGS costs JOBS_TIMEOUT x retries per
# call, and the callers here sit in per-candidate loops (one open PR, one train
# member), so a single hung worker turns an hourly flock'd lane into a lane that
# does not finish its tick. So the first unusable read or write latches the
# library off for the rest of the process. The direction is the documented
# fail-open one: latched off, a READ is rc 1 and never "already done", and a
# WRITE is rc 0 with the file line already on disk. The latch lives for one
# process only — the next tick asks again, the same latency the flag itself has.
#
# The latch is set in lt_seen and lt_put, which run in the CALLER's shell; it
# cannot be set inside lt_get, because every caller reads that one through a
# `$(...)` command substitution and a variable set in a subshell dies with it.
_LT_DOWN=0
lt_down() { [ "$_LT_DOWN" = 1 ]; } # rc 0 when the breaker is open

lt_get() { # lt_get <kind> <key> -> prints the status. rc 0 hit | 2 miss | 1 off/outage
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  lt_down && return 1
  lt_on || return 1
  declare -F job_ledger_get >/dev/null 2>&1 || return 1
  job_ledger_get "$1" "$2"
}

# lt_read <kind> <key> — the STATUS read, for the callers that want the value.
# It exists so the value read is not a `$(lt_get ...)` at the call site: the
# breaker has to be tripped in a shell that outlives the call, and a command
# substitution is not one. Sets LT_VAL (empty unless rc 0) and mirrors lt_get's
# rc, so `lt_read k v && use "$LT_VAL"` is the whole idiom.
LT_VAL=""
lt_read() {
  local rc
  LT_VAL=$(lt_get "$1" "$2"); rc=$?
  [ "$rc" -eq 1 ] && lt_on && _LT_DOWN=1
  [ "$rc" -eq 0 ] || LT_VAL=""
  return "$rc"
}

lt_seen() { # lt_seen <kind> <key> -> rc 0 when a row exists, whatever its status
  local st rc
  st=$(lt_get "$1" "$2"); rc=$?
  # Only rc 1 trips the breaker. rc 2 is a worker that answered "no such row",
  # which is the library working, and tripping on it would turn every genuinely
  # new candidate into a latched-off lane.
  [ "$rc" -eq 1 ] && lt_on && _LT_DOWN=1
  [ "$rc" -eq 0 ] && [ -n "$st" ]
}

lt_put() { # lt_put <kind> <key> <status> [detail] — write-through, always rc 0
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 0
  lt_down && return 0
  lt_on || return 0
  declare -F job_ledger_put >/dev/null 2>&1 || return 0
  job_ledger_put "$1" "$2" "$3" "${4:-}" >/dev/null 2>&1 || _LT_DOWN=1
  return 0
}

# THE ROW AS A RECORD, NOT A TWIN (BH-4156). bin/review-autopilot.sh keeps no
# file when the flag is up: the row is the only record. So it needs the two
# things the twin verbs above do not give: the row's DETAIL on a read, and a
# write that says whether it landed. Both keep the flag, the breaker and the
# rc contract of the verbs above.
#
# The column limits are the worker's (worker/jobs/src/routes/ledger.js, PUT
# /api/ledger): status is cut at 128 characters and detail at 4000, silently.
# A cut record is a record nobody wrote, so lt_put_rc REFUSES a value over
# either limit (rc 3) and sends nothing. The limit is counted in BYTES: the
# route counts UTF-16 units, and a UTF-8 byte count is never smaller.
LT_STATUS_MAX=128
LT_DETAIL_MAX=4000
LT_DETAIL=""

# lt_row <kind> <key> — the status AND the detail. Sets LT_VAL and LT_DETAIL
# (both empty unless rc 0). rc 0 hit | 2 no row | 1 off/outage/unparseable. An
# rc 1 trips the breaker, exactly as lt_read does.
lt_row() {
  local j rc=1
  LT_VAL=""; LT_DETAIL=""
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  lt_down && return 1
  lt_on || return 1
  declare -F job_ledger_row >/dev/null 2>&1 || return 1
  j=$(job_ledger_row "$1" "$2"); rc=$?
  if [ "$rc" = 0 ]; then
    LT_VAL=$(jq -r '.status // ""' <<<"$j" 2>/dev/null) || rc=1
    LT_DETAIL=$(jq -r '.detail // ""' <<<"$j" 2>/dev/null) || rc=1
    [ -n "$LT_VAL" ] || rc=1
  fi
  case "$rc" in 0|2) ;; *) rc=1 ;; esac
  [ "$rc" = 0 ] || { LT_VAL=""; LT_DETAIL=""; }
  [ "$rc" = 1 ] && _LT_DOWN=1
  return "$rc"
}

# lt_put_rc <kind> <key> <status> [detail] — a write that reports.
#   rc 0 written | 1 not written (flag off, breaker open, no client, the worker
#   refused or did not answer; the last two trip the breaker) | 3 refused: the
#   status or detail is over the column limit, nothing was sent.
lt_put_rc() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  [ "$(printf '%s' "$3" | wc -c)" -le "$LT_STATUS_MAX" ] || return 3
  [ "$(printf '%s' "${4:-}" | wc -c)" -le "$LT_DETAIL_MAX" ] || return 3
  lt_down && return 1
  lt_on || return 1
  declare -F job_ledger_put >/dev/null 2>&1 || return 1
  job_ledger_put "$1" "$2" "$3" "${4:-}" >/dev/null 2>&1 && return 0
  _LT_DOWN=1
  return 1
}

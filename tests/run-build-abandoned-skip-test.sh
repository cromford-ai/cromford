#!/bin/bash
# tests/run-build-abandoned-skip-test.sh — a ticket the blocked-resolver
# ABANDONED is not queued again by a watcher (2026-09-23 pool loop).
#
# BH-1681 was ABANDONED, and a watcher's triage (requested_by
# box-small) re-enqueued it at 19:04 and again at 00:06: queue_put
# turns a failed row back into a queued one, and nothing on the watcher could
# see the hub's ABANDONED record. The `abandoned ticket skip` block of
# bin/run-build.sh reads the fleet ledger row br_abandon now writes (and, for an
# abandon recorded before that, the row's own ABANDONED reason) BEFORE anything
# is queued.
#
# HOW IT DRIVES: the block is lifted out of the pipeline text (tests/lib/rb-all.sh,
# so the answer holds at every state of the BH-478 split) by its markers and
# executed with RESULT, the ledger read and the queue-row read stubbed; each
# case asserts on the RESULT line, the exit code and whether the script went on.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }

awk '/^# >>> abandoned ticket skip/{f=1} f{print} /^# <<< abandoned ticket skip/{exit}' "$RB" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || { bad "could not lift the 'abandoned ticket skip' block out of bin/run-build.sh"; echo "run-build-abandoned-skip: $PASS passed, $FAIL failed"; exit 1; }
bash -n "$T/block.sh" && ok || bad "the lifted block is not valid bash"
# It must run BEFORE the fly enqueue gate, or the row is re-queued before it is read.
AB=$(grep -n '^# >>> abandoned ticket skip' "$RB" | head -1 | cut -d: -f1)
EQ=$(grep -n 'Fly builder trial (Phase 2): enqueue gate' "$RB" | head -1 | cut -d: -f1)
[ -n "$AB" ] && [ -n "$EQ" ] && [ "$AB" -lt "$EQ" ] && ok || bad "the skip (line ${AB:-?}) must precede the fly enqueue gate (line ${EQ:-?})"

mkdir -p "$T/h" "$T/build"
# run_block <ledger-rc> <ledger-status> <row-rc> <row-tsv>
run_block() {
  : > "$T/result"
  LRC="$1" LST="$2" QRC="$3" QROW="$4" HARNESS="$T/h" BUILD="$T/build" PROJECT=tproj KEY=BH-1681 SINK="$T/result" \
  bash -c '
    STAMP() { echo 2026-09-23T19:04:00Z; }
    RESULT() { echo "$*" > "$SINK"; }
    job_ledger_get() { [ "$1" = abandoned ] && [ "$2" = "tproj BH-1681" ] || return 2; [ "$LRC" = 0 ] && printf "%s" "$LST"; return "$LRC"; }
    queue_row() { [ "$QRC" = 0 ] && printf "%s" "$QROW"; return "$QRC"; }
    . "$0"
    echo CONTINUED' "$T/block.sh" 2>/dev/null
}

OUT=$(run_block 0 abandoned 2 ""); RC=$?
[ "$RC" = 3 ] && ok || bad "1: a ledger ABANDONED must exit 3, got rc=$RC"
grep -q '^BUILD_REFUSED SKIP_ABANDONED BH-1681' "$T/result" && ok || bad "1: RESULT must be BUILD_REFUSED SKIP_ABANDONED, got: $(cat "$T/result")"
case "$OUT" in *CONTINUED*) bad "1: the script went on to queue an ABANDONED ticket" ;; *) ok ;; esac

OUT=$(run_block 2 "" 0 "$(printf 'failed\t2026-09-23T18:00:00Z\thub\thub\tABANDONED by the blocked-resolver: rebuilt fresh 3 times')"); RC=$?
[ "$RC" = 3 ] && grep -q '^BUILD_REFUSED SKIP_ABANDONED' "$T/result" && ok \
  || bad "2: a row still failed with the resolver's ABANDONED reason must refuse too (rc=$RC, $(cat "$T/result"))"

OUT=$(run_block 0 released 0 "$(printf 'failed\t-\t-\t-\tABANDONED by the blocked-resolver: x')"); RC=$?
case "$OUT" in *CONTINUED*) ok ;; *) bad "3: a RELEASED ledger row must let the build go on (rc=$RC)" ;; esac

OUT=$(run_block 1 "" 1 ""); RC=$?
case "$OUT" in *CONTINUED*) ok ;; *) bad "4: an outage must fail open (rc=$RC)" ;; esac
[ -s "$T/result" ] && bad "4: an outage wrote a RESULT: $(cat "$T/result")" || ok

OUT=$(run_block 2 "" 0 "$(printf 'failed\t-\t-\t-\tdeferred 6 times (BUILD_DEFERRED wip-limit)')"); RC=$?
case "$OUT" in *CONTINUED*) ok ;; *) bad "5: an ordinary failed row must not read as ABANDONED (rc=$RC)" ;; esac

# ── A PERSON'S RESUME LIFTS A LEDGER ABANDON (example-org/project-6 #3720) ─────
# AlbinB wrote RESUME on #3720 on 2026-11-10; the ledger row stayed `abandoned`
# and nothing built for 8 days. A lift comment (hold.sh: `clear<TAB>
# lifted-by-comment <at>`) NEWER than the row's updated_at releases the row and
# the build goes on. An older RESUME does not: the ladder ran again after it.
# run_resume <hold-verdict> <row updated_at>
run_resume() {
  : > "$T/result"; : > "$T/puts"
  HV="$1" LAT="$2" HARNESS="$T/h" BUILD="$T/build" PROJECT=tproj TICKET=1681 KEY=BH-1681 SINK="$T/result" PUTS="$T/puts" \
  JOBS_LIB="$DIR/bin/lib/jobs/jobs.sh" bash -c '
    . "$JOBS_LIB"
    STAMP() { echo 2026-11-10T16:00:00Z; }
    RESULT() { echo "$*" > "$SINK"; }
    _jobs_req() { printf "{\"ledger\":{\"kind\":\"abandoned\",\"status\":\"abandoned\",\"updated_at\":\"%s\"}}" "$LAT"; }
    job_ledger_put() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$PUTS"; }
    queue_row() { return 2; }
    to_build_hold() { printf "%s\n" "$HV"; return 1; }
    . "$0"
    echo CONTINUED' "$T/block.sh" 2>/dev/null
}
LIFT=$(printf 'clear\tlifted-by-comment 2026-11-10T15:54:28Z')

OUT=$(run_resume "$LIFT" 2026-11-09T20:00:00Z); RC=$?
case "$OUT" in *CONTINUED*) ok ;; *) bad "6: a RESUME newer than the abandon must let the build go on (rc=$RC, $(cat "$T/result"))" ;; esac
grep -qx 'abandoned|tproj BH-1681|released' "$T/puts" && ok || bad "6: the lift must put the ledger row released, got: $(cat "$T/puts")"
grep -q 'RESUME_LIFTS_ABANDONED BH-1681' "$T/build/pipeline.log" && ok || bad "6: the lift must be logged in pipeline.log"

OUT=$(run_resume "$LIFT" 2026-11-11T09:00:00Z); RC=$?
[ "$RC" = 3 ] && grep -q '^BUILD_REFUSED SKIP_ABANDONED' "$T/result" && ok \
  || bad "7: a RESUME older than the abandon must not lift it (rc=$RC, $(cat "$T/result"))"
[ -s "$T/puts" ] && bad "7: an old RESUME wrote the ledger: $(cat "$T/puts")" || ok

OUT=$(run_resume "$(printf 'clear\tno-hold')" 2026-11-09T20:00:00Z); RC=$?
[ "$RC" = 3 ] && [ ! -s "$T/puts" ] && ok || bad "8: no RESUME on the ticket keeps the abandon (rc=$RC, puts: $(cat "$T/puts"))"

OUT=$(run_resume "$(printf 'held\thold:comment 2026-11-10T15:54:28Z HOLD')" 2026-11-09T20:00:00Z); RC=$?
[ "$RC" = 3 ] && [ ! -s "$T/puts" ] && ok || bad "9: a held verdict never lifts an abandon (rc=$RC)"

echo "run-build-abandoned-skip: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

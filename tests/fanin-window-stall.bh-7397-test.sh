#!/bin/bash
# tests/fanin-window-stall.bh-7397-test.sh — BH-7397: the merge conductor's
# window-stall alert. A repo whose every enumerated PR is accounted
# deferred:window on MC_WINDOW_STALL_TICKS (2) fan-in runs in a row opens one
# warn alert with a stable id; the first later run that starts a PR resolves it.
#
# Every run below goes through the REAL fan-in entry points of bin/lib/fanin.sh
# (fanin_begin / fanin_enumerate / fanin_account / fanin_end), so each tally is
# the text _fanin_report really builds. bin/lane-alert.sh is a stub that records
# its argv.
#
#   S1  2 all-deferred runs (N=3): one open call, id mc-window-stall-o_r
#   S2  no alert: partial defer, deferred:solo, empty run, a single run, an
#       orphan ledger, lane reconcile-prs
#   S3  the alert text carries count 2 and enumerated 3
#   S4  a third all-deferred run sends the same id again (one id only)
#   S5  MC_WINDOW_STALL_TICKS=0: no alert after 3 runs
#   S6  MC_WINDOW_STALL_TICKS=x acts as 2
#   S7  no HARNESS/H: no file, no call, rc 0
#   S8  the keyed shape (N=1) twice opens; a run with one READY resolves with
#       the same id and the .window-stall row is gone
#   S9  two repos keep separate counts; an outcome with a space parses; a held
#       lock gives rc 0 and no change; no lane-alert.sh writes ALERTS.log
#   S10 a copy of fanin.sh without the fws_note call sends no alert
#
# Run from anywhere: tests/fanin-window-stall.bh-7397-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v flock >/dev/null 2>&1 || { echo "SKIP: flock missing"; exit 0; }

STALL_LIB=bin/lib/fanin-window-stall.sh
[ -s "$REPO/$STALL_LIB" ] && ok "source exists: $STALL_LIB" || bad "missing source $STALL_LIB"

F="$T/f"; mkdir -p "$F/bin" "$F/logs" || exit 1
( cd "$REPO" && scratch_install_closure bin/lib/fanin.sh "$F" ) >/dev/null 2>&1 || bad "setup: could not install bin/lib/fanin.sh"
[ -r "$F/$STALL_LIB" ] && ok "closure of fanin.sh installs $STALL_LIB" || bad "closure of fanin.sh lacks $STALL_LIB"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$F" > "$F/bin/lane-alert.sh"
chmod +x "$F/bin/lane-alert.sh"
FLOG="$F/logs/merge-conductor.log"
SF="$F/state/fanin/merge-conductor/.window-stall"
LIBDIR="$F/bin/lib"

reset_f() { scratch_rm "$F/state"; : > "$F/alerts.txt"; : > "$FLOG"; rm -f "$F/logs/ALERTS.log" "$F/bin/alert-line.sh"; }
nopen()  { grep -c -- '--severity warn --id mc-window-stall-' "$F/alerts.txt" 2>/dev/null || true; }
nres()   { grep -c -- '--resolve --id mc-window-stall-' "$F/alerts.txt" 2>/dev/null || true; }
ncalls() { grep -c . "$F/alerts.txt" 2>/dev/null || true; }
row()    { awk -F'\t' -v s="$1" '$1 == s { print $2 }' "$SF" 2>/dev/null; }

# _tick <lane> <scope> <outcome>... — one fan-in run, one PR per outcome.
_tick() {
  local lane="$1" scope="$2" i=0 o
  shift 2
  fanin_begin "$lane" "$scope" "$FLOG"
  for o in "$@"; do
    i=$((i+1))
    fanin_enumerate "$scope#$i"
    fanin_account "$scope#$i" "$o"
  done
  fanin_end
}
# tick <lane> <scope> <outcome>... — _tick in a fresh shell that sourced the lib.
tick() { ( export HARNESS="$F"; . "$LIBDIR/fanin.sh" 2>/dev/null || exit 9; _tick "$@" ); }
DW=deferred:window

# ── S1 / S3 ──────────────────────────────────────────────────────────────────
reset_f
tick merge-conductor o/r $DW $DW $DW
[ "$(ncalls)" = 0 ] && [ "$(row o/r)" = 1 ] && ok "S1 first all-deferred run: no alert, streak 1" || bad "S1 first run: calls=$(ncalls) row=$(row o/r)"
tick merge-conductor o/r $DW $DW $DW
[ "$(nopen)" = 1 ] && grep -q -- '--id mc-window-stall-o_r merge-conductor' "$F/alerts.txt" \
  && grep -q 'every PR deferred' "$F/alerts.txt" && ok "S1 second run: one open call, id mc-window-stall-o_r" \
  || bad "S1 second run: $(cat "$F/alerts.txt")"
grep -q 'deferred:window) on 2 runs in a row; last run enumerated 3' "$F/alerts.txt" \
  && ok "S3 text: count 2, enumerated 3" || bad "S3 text: $(cat "$F/alerts.txt")"
grep -q 'MERGE CONDUCTOR STALL o/r' "$FLOG" && ok "S3 conductor log line written" || bad "S3 no log line: $(cat "$FLOG")"

# ── S4 ───────────────────────────────────────────────────────────────────────
tick merge-conductor o/r $DW $DW $DW
ids=$(grep -o -- '--id [^ ]*' "$F/alerts.txt" | sort -u)
[ "$(nopen)" = 2 ] && [ "$ids" = "--id mc-window-stall-o_r" ] && [ "$(row o/r)" = 3 ] \
  && ok "S4 third run: same id again, streak 3" || bad "S4: opens=$(nopen) ids=$ids row=$(row o/r)"

# ── S2 negatives (each after one all-deferred run, so a wrong +1 would fire) ─
reset_f; tick merge-conductor o/r $DW $DW $DW; tick merge-conductor o/r $DW $DW READY
[ "$(ncalls)" = 0 ] && [ -z "$(row o/r)" ] && ok "S2c partial defer (2 deferred, 1 READY): no alert, row cleared" || bad "S2c: $(cat "$F/alerts.txt") row=$(row o/r)"
reset_f; tick merge-conductor o/r deferred:solo deferred:solo deferred:solo; tick merge-conductor o/r deferred:solo deferred:solo deferred:solo
[ "$(ncalls)" = 0 ] && [ -z "$(row o/r)" ] && ok "S2d deferred:solo x2: no alert" || bad "S2d: $(cat "$F/alerts.txt")"
reset_f; tick merge-conductor o/r $DW; tick merge-conductor o/r; tick merge-conductor o/r
[ "$(ncalls)" = 0 ] && [ "$(row o/r)" = 1 ] && ok "S2e empty runs: no alert, streak unchanged" || bad "S2e: calls=$(ncalls) row=$(row o/r)"
( export HARNESS="$F"; . "$LIBDIR/fanin-window-stall.sh"; fws_note x merge-conductor o/r 0 "" ) && [ "$(row o/r)" = 1 ] \
  && ok "S2e fws_note with N=0: rc 0, no change" || bad "S2e direct: row=$(row o/r)"
reset_f; tick merge-conductor o/r $DW $DW
[ "$(ncalls)" = 0 ] && ok "S2f a single all-deferred run: no alert" || bad "S2f: $(cat "$F/alerts.txt")"
# g: a dead run's ledger, all deferred, reported by the next begin as an orphan.
reset_f; tick merge-conductor o/r $DW
mkdir -p "$F/state/fanin/merge-conductor"
printf 'E o/r#1\nA o/r#1 deferred:window\nE o/r#2\n' > "$F/state/fanin/merge-conductor/o_r.999999"
( export HARNESS="$F"; . "$LIBDIR/fanin.sh"; fanin_begin merge-conductor o/r "$FLOG"; rm -f "$FANIN_FILE" )
[ "$(nopen)" = 0 ] && [ "$(row o/r)" = 1 ] && grep -q 'run died before fan-in' "$F/alerts.txt" \
  && ok "S2g orphan report: no stall alert, streak unchanged" || bad "S2g: $(cat "$F/alerts.txt") row=$(row o/r)"
reset_f; tick reconcile-prs fleet $DW $DW; tick reconcile-prs fleet $DW $DW
[ "$(ncalls)" = 0 ] && [ ! -e "$SF" ] && [ ! -e "$F/state/fanin/reconcile-prs/.window-stall" ] \
  && ok "S2h lane reconcile-prs: no alert, no state" || bad "S2h: $(cat "$F/alerts.txt")"

# ── S5 / S6 knob ─────────────────────────────────────────────────────────────
reset_f; for _ in 1 2 3; do MC_WINDOW_STALL_TICKS=0 tick merge-conductor o/r $DW; done
[ "$(ncalls)" = 0 ] && [ ! -e "$SF" ] && ok "S5 knob 0: off, no alert after 3 runs" || bad "S5: $(cat "$F/alerts.txt")"
reset_f; MC_WINDOW_STALL_TICKS=x tick merge-conductor o/r $DW
n1=$(ncalls); MC_WINDOW_STALL_TICKS=x tick merge-conductor o/r $DW
[ "$n1" = 0 ] && [ "$(nopen)" = 1 ] && ok "S6 knob x: acts as 2" || bad "S6: n1=$n1 opens=$(nopen)"
reset_f; MC_WINDOW_STALL_TICKS=3 tick merge-conductor o/r $DW; MC_WINDOW_STALL_TICKS=3 tick merge-conductor o/r $DW
n2=$(ncalls); MC_WINDOW_STALL_TICKS=3 tick merge-conductor o/r $DW
[ "$n2" = 0 ] && [ "$(nopen)" = 1 ] && ok "S6 knob 3: fires on the third run" || bad "S6 knob 3: n2=$n2 opens=$(nopen)"

# ── S7 no root ───────────────────────────────────────────────────────────────
reset_f
( unset HARNESS H; . "$LIBDIR/fanin-window-stall.sh"; cd "$T" || exit 9
  fws_note "$T/none" merge-conductor o/r 3 "deferred:window 3"; rc1=$?
  fws_note "$T/none" merge-conductor o/r 3 "deferred:window 3"; exit $((rc1 + $?)) ); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = 0 ] && [ ! -e "$SF" ] && [ ! -e "$T/state" ] && ok "S7 no root: rc 0, no file, no call" || bad "S7: rc=$rc calls=$(ncalls)"

# ── S8 the keyed shape and the resolve ───────────────────────────────────────
reset_f; tick merge-conductor o/r $DW; tick merge-conductor o/r $DW
[ "$(nopen)" = 1 ] && grep -q 'last run enumerated 1' "$F/alerts.txt" && ok "S8 keyed shape (N=1) twice: opens" || bad "S8 open: $(cat "$F/alerts.txt")"
tick merge-conductor o/r READY
[ "$(nres)" = 1 ] && grep -q -- '--resolve --id mc-window-stall-o_r merge-conductor .*recovered: READY 1' "$F/alerts.txt" \
  && [ -z "$(row o/r)" ] && ok "S8 a READY run: resolve, same id, row gone" || bad "S8 resolve: $(cat "$F/alerts.txt") row=$(row o/r)"
tick merge-conductor o/r READY
[ "$(nres)" = 1 ] && ok "S8 a second healthy run sends no second resolve" || bad "S8 resolve twice: $(nres)"
reset_f; tick merge-conductor o/r $DW; tick merge-conductor o/r READY
[ "$(nres)" = 0 ] && ok "S8 streak 1 then READY: no resolve (nothing was open)" || bad "S8 resolve w/o open: $(cat "$F/alerts.txt")"

# ── S9 two repos, a spaced outcome, a held lock, no lane-alert.sh ────────────
reset_f; tick merge-conductor o/a $DW $DW; tick merge-conductor o/b READY; tick merge-conductor o/a $DW
[ "$(nopen)" = 1 ] && grep -q -- '--id mc-window-stall-o_a ' "$F/alerts.txt" && [ -z "$(row o/b)" ] && [ "$(row o/a)" = 2 ] \
  && ok "S9i streaks are per repo" || bad "S9i: $(cat "$F/alerts.txt") a=$(row o/a) b=$(row o/b)"
reset_f; tick merge-conductor o/r $DW; tick merge-conductor o/r "READY held:worker-locked" $DW $DW
grep -q 'enumerated 3 accounted 3 (READY held:worker-locked 1, deferred:window 2)' "$FLOG" && [ "$(ncalls)" = 0 ] && [ -z "$(row o/r)" ] \
  && ok "S9j 'READY held:worker-locked 1, deferred:window 2' parses as not all deferred" || bad "S9j: $(cat "$F/alerts.txt") row=$(row o/r)"
reset_f; tick merge-conductor o/r $DW
before=$(cat "$SF")
exec 9>> "$SF.lock"; flock -x 9
( export HARNESS="$F"; . "$LIBDIR/fanin-window-stall.sh"; fws_note x merge-conductor o/r 1 "deferred:window 1" ); rc=$?
exec 9>&-
[ "$rc" = 0 ] && [ "$(cat "$SF")" = "$before" ] && [ "$(ncalls)" = 0 ] && ok "S9 lock held: rc 0, no change, no call" || bad "S9 lock: rc=$rc $(cat "$SF")"
# no lane-alert.sh: bin/alert-line.sh (a stub here) gets the same id
reset_f; mv "$F/bin/lane-alert.sh" "$T/lane-alert.off"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alert-line.txt"\nexit 0\n' "$F" > "$F/bin/alert-line.sh"; chmod +x "$F/bin/alert-line.sh"
: > "$F/alert-line.txt"
tick merge-conductor o/r $DW; tick merge-conductor o/r $DW; tick merge-conductor o/r READY
mv "$T/lane-alert.off" "$F/bin/lane-alert.sh"
grep -q -- '^--severity warn --id mc-window-stall-o_r MERGE CONDUCTOR STALL o/r: every PR' "$F/alert-line.txt" \
  && grep -q -- '^--severity resolved --id mc-window-stall-o_r MERGE CONDUCTOR STALL o/r recovered' "$F/alert-line.txt" \
  && grep -q 'MERGE CONDUCTOR STALL o/r' "$FLOG" \
  && ok "S9 no lane-alert.sh: alert-line.sh open and resolve, same id, and the log line" || bad "S9 fallback: $(cat "$F/alert-line.txt")"
# neither helper: the conductor log line is the record, rc 0
reset_f; mv "$F/bin/lane-alert.sh" "$T/lane-alert.off"
tick merge-conductor o/r $DW; tick merge-conductor o/r $DW; rc=$?
mv "$T/lane-alert.off" "$F/bin/lane-alert.sh"
[ "$rc" = 0 ] && grep -q 'MERGE CONDUCTOR STALL o/r' "$FLOG" && ok "S9 no helper at all: rc 0, the log line" || bad "S9 no helper: rc=$rc $(cat "$FLOG")"
# rows older than 7 days are dropped on the next write
reset_f; mkdir -p "${SF%/*}"; printf 'old/r\t5\t1000\n' > "$SF"; tick merge-conductor o/r $DW
[ -z "$(row old/r)" ] && [ "$(row o/r)" = 1 ] && ok "S9 a row older than 7 days is dropped" || bad "S9 expiry: $(cat "$SF")"

# ── S10 mutation: the wiring ─────────────────────────────────────────────────
M="$T/m"; mkdir -p "$M/bin/lib"
cp -p "$LIBDIR"/*.sh "$M/bin/lib/"
grep -q 'fws_note "\$file"' "$M/bin/lib/fanin.sh" && ok "S10 fanin.sh carries the fws_note call" || bad "S10 fanin.sh has no fws_note call"
sed -i '/fws_note "\$file"/d' "$M/bin/lib/fanin.sh"
reset_f
( export HARNESS="$F"; . "$M/bin/lib/fanin.sh"; _tick merge-conductor o/r $DW; _tick merge-conductor o/r $DW )
[ "$(ncalls)" = 0 ] && ok "S10 without the call line the S8 shape sends no alert" || bad "S10: $(cat "$F/alerts.txt")"

echo "fanin-window-stall: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/bin/bash
# tests/defer-report.bh-9426-test.sh — bin/defer-report.sh: for each
# BUILD_DEFERRED build dir, the files that collided and the ticket that held
# them; the top files by deferrals, the wait each deferral added, deferrals per
# ticket, the --out list the planner reads and one log line per lane run.
#
# The fixtures are build dirs named and filled the way production writes them:
#   RESULT "BUILD_DEFERRED OVERLAP_DEFER <K> vs <O> files=[p,q]; not before ..."
#     (bin/lib/rb/gates.sh rb_gate_overlap over bin/plan-overlap.sh /
#     bin/plan-sibling.sh stdout), the "; After: <O> — held ..." variant,
#   RESULT "BUILD_DEFERRED file overlap — CONFLICT with <dir>: p ~ q — still
#     overlapping after 0m; wakes when ..." (gates.sh over bin/conflict-check.sh),
#   other BUILD_DEFERRED lines (slots, not-before), PR_CREATED, no RESULT,
#   pool-/fly- relayed dirs. The clock is pinned with --now; no wall clock.
#
#   R1-R9   the report on a 7-day window (lane mode, no DEFER_REPORT_* knob set)
#   W1-W2   --last 1d drops older dirs; --project drops other projects
#   O1-O3   --out contents, order and atomic write; lane-mode default out file
#   L1-L4   one log line per lane run; --last runs write none; field values
#   T1      the default top is 20 rows; --top 2
#   E1-E3   bad flag rc 2 and no write; empty builds dir; DEFER_REPORT_ENABLED=0
#   M1-M2   mutations: no holder parse, no wait -> red
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin" "$H/builds" "$H/logs" "$H/state" "$H/flags"
scratch_install_closure bin/defer-report.sh "$H" >/dev/null || bad "closure install: bin/defer-report.sh"
NOW=$(date -u -d '2026-11-12 12:00:00' +%s)
B="$H/builds"

mk() { # mk <dirname> [RESULT line] — a build dir; no line = a running build
  mkdir -p "$B/$1"
  [ "$#" -ge 2 ] && printf '%s\n' "$2" > "$B/$1/RESULT"
  return 0
}
fixtures() {
  scratch_rm "$B"; mkdir -p "$B"
  # AB-1 deferred at 09:00 on src/pay.ts held by AB-2; rebuilt at 09:25 -> wait 25
  mk acme-AB-1-202611120900 "BUILD_DEFERRED OVERLAP_DEFER AB-1 vs AB-2 files=[src/pay.ts,src/pay.ts]; not before 2026-11-12 09:10:00Z, then the next triage tick re-offers AB-1 to any free box"
  mk acme-AB-1-202611120925 "PR_CREATED https://github.com/example-org/acme/pull/11"
  # AB-3: two files, the After: variant, no later build -> open
  mk acme-AB-3-202611121000 "BUILD_DEFERRED OVERLAP_DEFER AB-3 vs AB-2 files=[src/pay.ts,src/pay.ts,src/ui/card.tsx,src/ui/card.tsx]; After: AB-2 — held until it merges (not before 2026-11-12 10:10:00Z), then the next triage tick re-offers AB-3 to any free box"
  # AB-4: the in-build wait shape, rebuilt at 10:45 -> wait 35; that rebuild is a non-file deferral, open
  mk acme-AB-4-202611121010 "BUILD_DEFERRED file overlap — CONFLICT with acme-AB-2-202611120800: src/pay.ts ~ src/pay.ts — still overlapping after 0m; wakes when the sibling releases its claim and the next triage tick re-offers AB-4"
  mk acme-AB-4-202611121045 "BUILD_DEFERRED all 4 slots busy"
  # AB-5 shipped; its text mentions OVERLAP_DEFER but it is not a deferral
  mk acme-AB-5-202611121100 "PR_CREATED https://github.com/example-org/acme/pull/12 (after OVERLAP_DEFER AB-5 vs AB-2 files=[src/pay.ts,src/pay.ts])"
  # AB-6 nine days old: outside the 7-day window
  mk acme-AB-6-202611030900 "BUILD_DEFERRED OVERLAP_DEFER AB-6 vs AB-2 files=[src/old.ts,src/old.ts]; not before 2026-11-03 09:10:00Z"
  # another project, same file
  mk other-AB-7-202611121000 "BUILD_DEFERRED OVERLAP_DEFER AB-7 vs AB-70 files=[src/pay.ts,src/pay.ts]; not before 2026-11-12 10:10:00Z"
  # AB-8 27 h old: inside 7d, outside 1d; holder AB-9
  mk acme-AB-8-202611110900 "BUILD_DEFERRED OVERLAP_DEFER AB-8 vs AB-9 files=[lib/x.sh,lib/x.sh]; not before 2026-11-11 09:10:00Z"
  # a relayed pool dir, 14-digit stamp, holder AB-2
  mk pool-acme-AB-11-20261112113000 "BUILD_DEFERRED OVERLAP_DEFER AB-11 vs AB-2 files=[src/pay.ts,src/pay.ts]; not before 2026-11-12 11:40:00Z"
  # a not-before re-deferral: a deferral, but it names no file
  mk acme-AB-12-202611121105 "BUILD_DEFERRED plan overlap not-before 11:10:00Z — AB-12 stood down on a file overlap and its window has 5m left"
  # a running build (no RESULT) and a fly-ingested PR
  mk acme-AB-13-202611121130
  mk fly-acme-AB-14-20261112114500 "PR_CREATED https://github.com/example-org/acme/pull/14"
  # a dir that is not a build dir name at all
  mkdir -p "$B/acme-notes"
}
# acme in 7d: AB-1 x2, AB-3, AB-4 x2, AB-5, AB-8, AB-11, AB-12, AB-13, AB-14 = 11 builds
# deferred: AB-1@0900, AB-3, AB-4@1010, AB-4@1045, AB-8, AB-11, AB-12 = 7
# attributed: AB-1, AB-3, AB-4@1010, AB-8, AB-11 = 5; other: AB-4@1045, AB-12 = 2

dr() { # dr [args...] -> RC OUT ERR (lane gate off, scratch harness, pinned clock)
  OUT=$(env -u DEFER_REPORT_WINDOW_DAYS -u DEFER_REPORT_TOP -u DEFER_REPORT_ENABLED \
        LANE_GATE_DISABLE=1 HARNESS="$H" bash "$H/bin/defer-report.sh" --builds "$B" --now "$NOW" "$@" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
row() { # row <path> -> the TOP FILES row of that path
  awk -v p="$1" '/^TOP FILES/{f=1;next} /^PER TICKET/{f=0} f && $5==p' <<<"$OUT"
}
trow() { awk -v k="$1" '/^PER TICKET/{f=1;next} f && $1==k' <<<"$OUT"; }

# ============================ R. the 7-day report ============================
fixtures
: > "$H/logs/defer-report.log"
dr --project acme
[ "$RC" = 0 ] && ok || bad "R0: rc=$RC err=[$ERR]"
case "$OUT" in *"project=acme window=7d"*) ok ;; *) bad "R1: header must name project=acme window=7d (the default), got [$(head -1 <<<"$OUT")]" ;; esac
grep -q 'builds=11 deferred=7 attributed=5 other=2 share=63.6%' <<<"$OUT" && ok \
  || bad "R2: totals must be builds=11 deferred=7 attributed=5 other=2 share=63.6%, got [$(head -2 <<<"$OUT")]"
# src/pay.ts: AB-1 (25), AB-3 (open), AB-4 (35), AB-11 (open): count 4, total 60, median 30, open 2, holder AB-2 x4
read -r c tw md op p h <<<"$(row src/pay.ts)"
[ "$c $tw $md $op $p $h" = "4 60 30 open=2 src/pay.ts holders=AB-2(4)" ] && ok \
  || bad "R3: src/pay.ts row wrong: [$(row src/pay.ts)]"
read -r c tw md op p h <<<"$(row src/ui/card.tsx)"
[ "$c $tw $md $op $p $h" = "1 0 - open=1 src/ui/card.tsx holders=AB-2(1)" ] && ok \
  || bad "R4: src/ui/card.tsx row wrong (open wait, no median): [$(row src/ui/card.tsx)]"
read -r c tw md op p h <<<"$(row lib/x.sh)"
[ "$c $p $h" = "1 lib/x.sh holders=AB-9(1)" ] && ok || bad "R5: lib/x.sh must be held by AB-9: [$(row lib/x.sh)]"
# order: by count, then name
ORDER=$(awk '/^TOP FILES/{f=1;next} /^PER TICKET/{f=0} f && NF>=6 {print $5}' <<<"$OUT" | paste -sd' ')
[ "$ORDER" = "src/pay.ts lib/x.sh src/ui/card.tsx" ] && ok || bad "R6: TOP FILES order wrong: [$ORDER]"
# not counted against any file
for p in src/old.ts; do [ -z "$(row "$p")" ] && ok || bad "R7: $p is outside the window and must not appear"; done
grep -q 'slots' <<<"$(awk '/^TOP FILES/{f=1;next} /^PER TICKET/{f=0} f' <<<"$OUT")" && bad "R7: a slots deferral must never be a file row" || ok
# PER TICKET: KEY deferrals total_wait_m open=<n>
[ "$(trow AB-1)" = "AB-1 1 25 open=0" ] && ok || bad "R8: AB-1 per-ticket row: [$(trow AB-1)]"
[ "$(trow AB-4)" = "AB-4 2 35 open=1" ] && ok || bad "R8: AB-4 per-ticket row (file + slots deferral): [$(trow AB-4)]"
[ "$(trow AB-12)" = "AB-12 1 0 open=1" ] && ok || bad "R8: AB-12 per-ticket row: [$(trow AB-12)]"
[ "$(trow AB-11)" = "AB-11 1 0 open=1" ] && ok || bad "R8: AB-11 (pool dir) per-ticket row: [$(trow AB-11)]"
for k in AB-5 AB-13 AB-14 AB-6 AB-7; do
  [ -z "$(trow "$k")" ] && ok || bad "R9: $k has no deferral in acme's window and must have no PER TICKET row"
done

# ============================ W. window and project ============================
dr --project acme --last 1d
grep -q 'builds=10 deferred=6 attributed=4 other=2' <<<"$OUT" && ok || bad "W1: --last 1d must drop AB-8 (27 h old): [$(head -2 <<<"$OUT")]"
[ -z "$(row lib/x.sh)" ] && ok || bad "W1: lib/x.sh is 27 h old and must not be in --last 1d"
case "$OUT" in *"window=1d"*) ok ;; *) bad "W1: header must say window=1d" ;; esac
dr --project other --last 7d
grep -q 'builds=1 deferred=1 attributed=1 other=0' <<<"$OUT" && ok || bad "W2: --project other must see only AB-7: [$(head -2 <<<"$OUT")]"
grep -q '^note: window truncated: the oldest other build dir is 2026-11-12T10:00Z' <<<"$OUT" && ok \
  || bad "W2: other's only dir is 22 h old in a 7d window, so the report must say the window is truncated"
read -r c tw md op p h <<<"$(row src/pay.ts)"
[ "$c $h" = "1 holders=AB-70(1)" ] && ok || bad "W2: other's src/pay.ts row: [$(row src/pay.ts)]"

# ============================ O. --out ============================
dr --project acme --last 7d --out "$T/top.txt"
[ "$(cat "$T/top.txt" 2>/dev/null | paste -sd' ')" = "src/pay.ts lib/x.sh src/ui/card.tsx" ] && ok \
  || bad "O1: --out must hold the TOP FILES paths in order: [$(cat "$T/top.txt" 2>/dev/null)]"
ls "$T"/top.txt.* >/dev/null 2>&1 && bad "O2: --out left a temp file behind" || ok
rm -f "$H/state/defer-report/acme-top.txt"
dr --project acme
[ "$(paste -sd' ' "$H/state/defer-report/acme-top.txt" 2>/dev/null)" = "src/pay.ts lib/x.sh src/ui/card.tsx" ] && ok \
  || bad "O3: lane mode must write state/defer-report/acme-top.txt"

# ============================ L. the log ============================
: > "$H/logs/defer-report.log"
dr --project acme
dr --project acme
grep -q '^note: window truncated' <<<"$OUT" && bad "L1: acme holds a dir older than the window (AB-6), so no truncation note" || ok
[ "$(wc -l < "$H/logs/defer-report.log")" = 2 ] && ok || bad "L1: two lane runs must append two lines, got $(wc -l < "$H/logs/defer-report.log")"
dr --project acme --last 7d
[ "$(wc -l < "$H/logs/defer-report.log")" = 2 ] && ok || bad "L2: a --last run is not the daily summary and must not log"
L=$(tail -1 "$H/logs/defer-report.log")
for f in project=acme window=7d builds=11 deferred=7 attributed=5 other=2 share=63.6% 'top=src/pay.ts(4)'; do
  case " $L " in *" $f "*) ok ;; *) bad "L3: log line lacks '$f': [$L]" ;; esac
done
# no --project in lane mode: every project in the window, one line and one out file each
: > "$H/logs/defer-report.log"; scratch_rm "$H/state/defer-report"
dr
[ "$(wc -l < "$H/logs/defer-report.log")" = 2 ] && ok || bad "L4: lane mode over 2 projects must log 2 lines, got $(wc -l < "$H/logs/defer-report.log")"
[ -s "$H/state/defer-report/acme-top.txt" ] && [ -s "$H/state/defer-report/other-top.txt" ] && ok \
  || bad "L4: lane mode must write one top file per project"

# ============================ T. top N ============================
scratch_rm "$B"; mkdir -p "$B"
FL=""; for i in $(seq -w 1 25); do FL="${FL:+$FL,}src/f$i.ts,src/f$i.ts"; done
mk acme-AB-20-202611121000 "BUILD_DEFERRED OVERLAP_DEFER AB-20 vs AB-21 files=[$FL]; not before 2026-11-12 10:10:00Z"
dr --project acme
N=$(awk '/^TOP FILES/{f=1;next} /^PER TICKET/{f=0} f && NF>=6' <<<"$OUT" | wc -l)
[ "$N" = 20 ] && ok || bad "T1: the default top is 20 rows, got $N"
dr --project acme --top 2
N=$(awk '/^TOP FILES/{f=1;next} /^PER TICKET/{f=0} f && NF>=6' <<<"$OUT" | wc -l)
[ "$N" = 2 ] && ok || bad "T1: --top 2 must print 2 rows, got $N"

# ============================ E. edges ============================
fixtures; : > "$H/logs/defer-report.log"; rm -f "$T/bad.txt"
dr --bogus --out "$T/bad.txt"
[ "$RC" = 2 ] && ok || bad "E1: a bad flag must exit 2, got $RC"
[ ! -e "$T/bad.txt" ] && [ ! -s "$H/logs/defer-report.log" ] && ok || bad "E1: a bad flag must write nothing"
dr --last x7 --project acme
[ "$RC" = 2 ] && ok || bad "E1: --last x7 must exit 2, got $RC"
scratch_rm "$B"; mkdir -p "$B"
dr --project acme --last 7d
[ "$RC" = 0 ] && grep -q 'builds=0 deferred=0 attributed=0 other=0 share=0.0%' <<<"$OUT" && ok \
  || bad "E2: an empty builds dir must report zeros, rc=$RC out=[$(head -2 <<<"$OUT")]"
scratch_rm "$H/state/defer-report"
dr
[ "$RC" = 0 ] && [ ! -e "$H/state/defer-report/all-top.txt" ] && ok || bad "E2: a lane run over no build dirs must write no top file, rc=$RC"
fixtures; : > "$H/logs/defer-report.log"
OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$H" DEFER_REPORT_ENABLED=0 bash "$H/bin/defer-report.sh" --builds "$B" --now "$NOW" --project acme 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -s "$H/logs/defer-report.log" ] && ok || bad "E3: DEFER_REPORT_ENABLED=0 must stop the lane run, rc=$RC log=[$(cat "$H/logs/defer-report.log")]"
OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$H" DEFER_REPORT_WINDOW_DAYS=1 bash "$H/bin/defer-report.sh" --builds "$B" --now "$NOW" --project acme 2>&1)
case "$OUT" in *"window=1d"*) ok ;; *) bad "E3: DEFER_REPORT_WINDOW_DAYS=1 must set a 1d lane window" ;; esac

# ============================ M. mutations ============================
mut() { # mut <name> <sed expr> -> runs the mutant over the fixtures, sets OUT
  sed "$2" "$DIR/bin/defer-report.sh" > "$H/bin/defer-report-$1.sh"
  cmp -s "$H/bin/defer-report-$1.sh" "$DIR/bin/defer-report.sh" && bad "$1: the mutant changed nothing"
  OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$H" bash "$H/bin/defer-report-$1.sh" --builds "$B" --now "$NOW" --project acme --last 7d 2>/dev/null)
}
fixtures
mut M1 's/holder=\${BASH_REMATCH\[1\]}/holder=""/'
[ "$(awk '{print $6}' <<<"$(row src/pay.ts)")" = "holders=AB-2(4)" ] && bad "M1: the suite cannot see a lost holder parse" || ok
mut M2 's/wait=\$(( (nxt - ep) \/ 60 ))/wait=0/'
[ "$(awk '{print $2}' <<<"$(row src/pay.ts)")" = 60 ] && bad "M2: the suite cannot see a lost wait" || ok

echo "defer-report.bh-9426: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

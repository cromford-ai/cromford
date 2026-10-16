#!/bin/bash
# tests/group-findings-console-replay.bh-6902-test.sh — BH-6902 C2: the T5
# replay also reads the console post-merge QA runs that C1 wired to gf_run
# ($HARNESS/state/console-postmerge-qa/<sha40>/observed.json, board
# cromford), so the before/after count covers both QA lanes.
#
# Drives the real "$DIR/bin/group-findings-replay.sh" over scratch console run
# dirs made from the qa-drive fixtures in tests/fixtures/bh-6902/.
#
#   K1  one console run under the default dir, no flag, no builds: console: runs=1,
#       board=cromford findings=8, rc 0
#   K2  one build run plus two console runs on the same screens: total findings
#       is the sum of all three, builds=1, cromford after counts each screen
#       once, cut >= 50%
#   K3  a dist-<sha40> dir, a dir named abc and a run dir with no observed.json
#       are not read
#   K4  a console run older than --days is not read
#   K5  a console observed.json that is not JSON is a skipped line, not a finding
#   K6  --console with no value or an empty value is rc 2; --console /nope is runs=0 (absent)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/group-findings-console-replay.bh-6902-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "group-findings-console-replay.bh-6902: jq is required"; exit 1; }

FIX="$DIR/tests/fixtures/bh-6902"
H="$T/h"
if ! scratch_install_closure bin/group-findings-replay.sh "$H" >/dev/null; then
  echo "FAIL: cannot install bin/group-findings-replay.sh"; echo "group-findings-console-replay.bh-6902: 0 passed, 1 failed"; exit 1
fi
RP="$H/bin/group-findings-replay.sh"
NOW=2000000000
SHA1=$(printf 'a%.0s' $(seq 40)); SHA2=$(printf 'b%.0s' $(seq 40)); SHA3=$(printf 'c%.0s' $(seq 40))
crun() { # crun <console-dir> <run-dir-name> <fixture> <age-days>
  mkdir -p "$1/$2"; cp "$3" "$1/$2/observed.json"
  touch -d "@$((NOW - $4 * 86400))" "$1/$2/observed.json"
}
replay() { GF_REPLAY_NOW=$NOW HARNESS="$H" "$RP" "$@" 2>&1; }
mkdir -p "$H/builds"

# --- K1: the default console dir, no flag ------------------------------------------
CD="$H/state/console-postmerge-qa"
crun "$CD" "$SHA1" "$FIX/observed-fail.json" 1
OUT=$(replay --days 7); RC=$?
[ "$RC" = 0 ] && ok || bad "K1: rc=$RC: $OUT"
grep -qx "console: runs=1 dir=$CD" <<<"$OUT" && ok || bad "K1: want 'console: runs=1 dir=$CD': $OUT"
grep -q '^board=cromford findings=8 before=8 after=[0-9]* cut=[0-9]*% lost=0$' <<<"$OUT" \
  && ok || bad "K1: want a board=cromford findings=8 line: $OUT"
grep -q '^total: builds=0 skipped=0 findings=8 ' <<<"$OUT" && ok || bad "K1: total line: $OUT"
# The console line comes before the board= lines.
[ "$(grep -n '^console: ' <<<"$OUT" | cut -d: -f1)" -lt "$(grep -n '^board=' <<<"$OUT" | head -1 | cut -d: -f1)" ] 2>/dev/null \
  && ok || bad "K1: the console: line must come before the board= lines: $OUT"

# --- K2: one build plus two console runs -----------------------------------------
B="$T/k2/builds"; C="$T/k2/console"
mkdir -p "$B/project-3-TK-1-202609300000/qa-prod-shots"
cp "$FIX/observed-fail.json" "$B/project-3-TK-1-202609300000/qa-prod-shots/observed.json"
touch -d "@$((NOW - 86400))" "$B/project-3-TK-1-202609300000/qa-prod-shots/observed.json"
crun "$C" "$SHA1" "$FIX/observed-fail.json" 1      # 8 findings
crun "$C" "$SHA2" "$FIX/observed-second.json" 2    # 6 findings
OUT=$(replay --days 7 --builds "$B" --console "$C"); RC=$?
[ "$RC" = 0 ] && ok || bad "K2: rc=$RC: $OUT"
grep -qx "console: runs=2 dir=$C" <<<"$OUT" && ok || bad "K2: console line: $OUT"
grep -q '^board=cromford findings=14 before=14 after=4 cut=71% lost=0$' <<<"$OUT" \
  && ok || bad "K2: want 'board=cromford findings=14 before=14 after=4 cut=71% lost=0': $OUT"
grep -q '^board=project-3 findings=8 before=8 ' <<<"$OUT" && ok || bad "K2: project-3 line: $OUT"
grep -q '^total: builds=1 skipped=0 findings=22 before=22 ' <<<"$OUT" && ok || bad "K2: total must sum 8+8+6=22 with builds=1: $OUT"
CUT=$(sed -n 's/^total: .* cut=\([0-9]*\)%.*/\1/p' <<<"$OUT")
[ "${CUT:-0}" -ge 50 ] && ok || bad "K2: the cut must be at least 50%, got ${CUT:-none}"

# --- K3: dist-<sha40> and a non-hex name are not read ----------------------------
crun "$C" "dist-$SHA3" "$FIX/observed-fail.json" 1
crun "$C" abc "$FIX/observed-fail.json" 1
mkdir -p "$C/$(printf 'e%.0s' $(seq 40))"   # a run dir with no observed.json (an off run)
OUT=$(replay --days 7 --builds "$B" --console "$C")
grep -qx "console: runs=2 dir=$C" <<<"$OUT" && ok || bad "K3: dist-* and abc must not count: $OUT"
grep -q '^total: builds=1 skipped=0 findings=22 ' <<<"$OUT" && ok || bad "K3: dist-* and abc findings must not count: $OUT"

# --- K4: a console run older than the window -------------------------------------
crun "$C" "$SHA3" "$FIX/observed-fail.json" 30
OUT=$(replay --days 7 --builds "$B" --console "$C")
grep -qx "console: runs=2 dir=$C" <<<"$OUT" && ok || bad "K4: a 30-day-old run must not count: $OUT"
grep -q '^total: builds=1 skipped=0 findings=22 ' <<<"$OUT" && ok || bad "K4: old run findings: $OUT"
OUT=$(replay --days 40 --builds "$B" --console "$C")
grep -qx "console: runs=3 dir=$C" <<<"$OUT" && ok || bad "K4: with --days 40 the old run counts: $OUT"

# --- K5: a console observed.json that is not JSON -------------------------------
SHA4=$(printf 'd%.0s' $(seq 40))
mkdir -p "$C/$SHA4"; echo '{not json' > "$C/$SHA4/observed.json"
touch -d "@$((NOW - 86400))" "$C/$SHA4/observed.json"
OUT=$(replay --days 7 --builds "$B" --console "$C")
grep -qx "skipped $C/$SHA4/observed.json (not a readable observed.json)" <<<"$OUT" && ok || bad "K5: the bad file must be named: $OUT"
grep -qx "console: runs=2 dir=$C" <<<"$OUT" && ok || bad "K5: a bad file is not a run: $OUT"
grep -q '^total: builds=1 skipped=1 findings=22 ' <<<"$OUT" && ok || bad "K5: total: $OUT"

# --- K6: usage and an absent dir ------------------------------------------------
"$RP" --console >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "K6: --console with no value must answer rc 2, got $RC"
"$RP" --console "" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "K6: an empty --console must answer rc 2, got $RC"
grep -q -- '--console' <<<"$("$RP" --help 2>&1)" && ok || bad "K6: --help must name --console"
OUT=$(replay --days 7 --builds "$B" --console /nope); RC=$?
[ "$RC" = 0 ] && ok || bad "K6: an absent console dir is not an error, rc=$RC: $OUT"
grep -qx 'console: runs=0 dir=/nope (absent)' <<<"$OUT" && ok || bad "K6: want 'console: runs=0 dir=/nope (absent)': $OUT"
grep -q '^total: builds=1 skipped=0 findings=8 ' <<<"$OUT" && ok || bad "K6: builds still count: $OUT"

echo "group-findings-console-replay.bh-6902: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

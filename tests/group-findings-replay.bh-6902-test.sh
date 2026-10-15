#!/bin/bash
# tests/group-findings-replay.bh-6902-test.sh — BH-6902 T5: the replay of past
# post-merge QA runs reports issues before (one per finding) and after (one per
# screen or flow), and proves no finding is lost.
#
# Drives the real "$DIR/bin/group-findings-replay.sh" over scratch build dirs
# made from the qa-drive observed.json fixtures in tests/fixtures/bh-6902/.
#
#   R1  3 build dirs, 14 findings across 4 keys, one build older than 7 days:
#       before=14 after=4 lost=0, cut >= 50%, the old build left out, rc 0
#   R2  an unreadable observed.json is counted as skipped, not as 0 findings
#   R3  --help prints the usage line from the script header; a bad flag is rc 2
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/group-findings-replay.bh-6902-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "group-findings-replay.bh-6902: jq is required"; exit 1; }

FIX="$DIR/tests/fixtures/bh-6902"
H="$T/h"
if ! scratch_install_closure bin/group-findings-replay.sh "$H" >/dev/null; then
  echo "FAIL: cannot install bin/group-findings-replay.sh"; echo "group-findings-replay.bh-6902: 0 passed, 1 failed"; exit 1
fi
RP="$H/bin/group-findings-replay.sh"
NOW=2000000000
build() { # build <name> <fixture> <age-days>
  local d="$T/builds/$1/qa-prod-shots"
  mkdir -p "$d"; cp "$2" "$d/observed.json"
  touch -d "@$((NOW - $3 * 86400))" "$d/observed.json"
}

# --- R1 ---------------------------------------------------------------------------
build project-3-TK-1-202609300000 "$FIX/observed-fail.json" 1      # 8 findings
build project-3-TK-2-202610010000 "$FIX/observed-second.json" 3    # 6 findings
build project-3-TK-3-202609010000 "$FIX/observed-fail.json" 30     # too old
OUT=$(GF_REPLAY_NOW=$NOW HARNESS="$H" "$RP" --days 7 --builds "$T/builds" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R1: rc=$RC: $OUT"
grep -q '^board=project-3 findings=14 before=14 after=4 cut=71% lost=0$' <<<"$OUT" \
  && ok || bad "R1: want 'board=project-3 findings=14 before=14 after=4 cut=71% lost=0': $OUT"
grep -q '^total: builds=2 skipped=0 findings=14 before=14 after=4 cut=71% lost=0$' <<<"$OUT" \
  && ok || bad "R1: total line: $OUT"
CUT=$(sed -n 's/^total: .* cut=\([0-9]*\)%.*/\1/p' <<<"$OUT")
[ "${CUT:-0}" -ge 50 ] && ok || bad "R1: the cut must be at least 50%, got ${CUT:-none}"

# --- R2 ---------------------------------------------------------------------------
mkdir -p "$T/builds/project-3-TK-4-202610020000/qa-prod-shots"
echo '{not json' > "$T/builds/project-3-TK-4-202610020000/qa-prod-shots/observed.json"
touch -d "@$((NOW - 86400))" "$T/builds/project-3-TK-4-202610020000/qa-prod-shots/observed.json"
OUT=$(GF_REPLAY_NOW=$NOW HARNESS="$H" "$RP" --days 7 --builds "$T/builds" 2>&1); RC=$?
grep -q '^total: builds=2 skipped=1 findings=14 ' <<<"$OUT" && ok || bad "R2: an unreadable file must be skipped=1: $OUT"
grep -q 'skipped .*project-3-TK-4-202610020000' <<<"$OUT" && ok || bad "R2: the skipped file must be named: $OUT"

# A run of a second board is reported on its own line.
build project-4-TK-9-202610030000 "$FIX/observed-second.json" 2
OUT=$(GF_REPLAY_NOW=$NOW HARNESS="$H" "$RP" --days 7 --builds "$T/builds" 2>&1)
grep -q '^board=project-4 findings=6 before=6 after=4 cut=33% lost=0$' <<<"$OUT" && ok || bad "R2: project-4 line: $OUT"

# --- R4: a finding no group can hold is LOST, and lost is rc 1 -------------------------
# (A screen record with an empty path: the key normaliser gives it no key.)
mkdir -p "$T/lost/project-3-TK-5-202610040000/qa-prod-shots"
jq '.screens[0].path = ""' "$FIX/observed-second.json" > "$T/lost/project-3-TK-5-202610040000/qa-prod-shots/observed.json"
touch -d "@$((NOW - 86400))" "$T/lost/project-3-TK-5-202610040000/qa-prod-shots/observed.json"
OUT=$(GF_REPLAY_NOW=$NOW HARNESS="$H" "$RP" --days 7 --builds "$T/lost" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "R4: a lost finding must answer rc 1, got $RC: $OUT"
grep -q '^board=project-3 findings=6 before=6 after=4 cut=33% lost=1$' <<<"$OUT" && ok || bad "R4: $OUT"

# --- R3 ---------------------------------------------------------------------------
USAGE=$(sed -n 's/^# usage: //p' "$DIR/bin/group-findings-replay.sh" | head -1)
[ -n "$USAGE" ] && ok || bad "R3: the script header has no '# usage:' line"
OUT=$("$RP" --help 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R3: --help rc=$RC"
grep -qF "usage: $USAGE" <<<"$OUT" && ok || bad "R3: --help must print the header usage line: $OUT"
"$RP" --bogus >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "R3: an unknown flag must answer rc 2, got $RC"
"$RP" --days x >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "R3: a non-numeric --days must answer rc 2, got $RC"

echo "group-findings-replay.bh-6902: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

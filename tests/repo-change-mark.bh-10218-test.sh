#!/bin/bash
# tests/repo-change-mark.bh-10218-test.sh — BH-10218 W2: bin/lib/repo-change-mark.sh,
# a repo's change mark read from the wake mirror (never from GitHub).
#
#   M1 the mark is the highest wake id the mirror read for THIS repo
#   M2 quiet: no wake of the kinds above the mark (a pr wake, another repo's
#      push, a push with an id EQUAL to the mark do not move it)
#   M3 moved: a push wake above the mark, even with an OLDER clock (`at`)
#   M4 kind repo: moves `repo` and `push,repo`, not `push`
#   M5 cannot tell (rc 2): feed down, feed stale, a non-digit mark, a mark above
#      the mirror's wm, a stamp past the mirror's horizon, a stamp before its
#      coverage, no harness root
#   M6 no network: every worker read is the fixture's (wakes, the summary, and
#      the knob read lib_env_apply makes, which the fixture refuses)
#
# Run from anywhere: bash tests/repo-change-mark.bh-10218-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wake-feed-fixture.bh-10218.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/repo-change-mark.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "repo-change-mark: 0 passed, 1 failed"; exit 1; }

NOW=$(date +%s)   # the one clock read; the mirror itself reads the real clock
export HARNESS="$T/h"; mkdir -p "$HARNESS"
export PR_SNAPSHOT_TTL_S=0 PR_SNAPSHOT_FEED_STALE_S=900
unset GH_TOKEN GITHUB_TOKEN
wf_init
# A driver process: the stubs, then the lib, then one call. rc is the call's.
rcm() { ( . "$WF_STUBS"; . "$LIB"; "$@" ); }
rc_of() { local rc=0; rcm "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
eq() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', wanted '$3'"; }

wf_wake o/r pr 12 5
wf_wake o/r push aaaaaaa 7
wf_wake o/r-c push bbbbbbb 9

# M1
eq "M1 mark = highest wake id of o/r" "$(rcm rcm_mark o/r)" 7
eq "M1 mark of the other repo" "$(rcm rcm_mark o/r-c)" 9
# A memo is stamped after its mark is taken, so after the first complete read.
STAMP=$(date +%s)
# M2
eq "M2 quiet at the mark" "$(rc_of rcm_moved o/r push,repo 7 "$STAMP")" 1
wf_wake o/r pr 12 8
eq "M2 a pr wake does not move it" "$(rc_of rcm_moved o/r push,repo 7 "$STAMP")" 1
wf_wake o/r-c push ccccccc 10
eq "M2 another repo's push does not move it (a/b vs a/b-c)" "$(rc_of rcm_moved o/r push,repo 7 "$STAMP")" 1
eq "M2 a push with an id equal to the mark does not move it" "$(rc_of rcm_moved o/r push 7 "$STAMP")" 1
# M3
wf_wake o/r push ddddddd 11 $((NOW - 7200))
eq "M3 a push with a higher id and an older at moves it" "$(rc_of rcm_moved o/r push,repo 7 "$STAMP")" 0
eq "M3 push only" "$(rc_of rcm_moved o/r push 7 "$STAMP")" 0
eq "M3 the new mark" "$(rcm rcm_mark o/r)" 11
# M4
wf_wake o/r repo 123456789 12
eq "M4 a repo wake moves kind repo" "$(rc_of rcm_moved o/r repo 11 "$STAMP")" 0
eq "M4 a repo wake moves push,repo" "$(rc_of rcm_moved o/r push,repo 11 "$STAMP")" 0
eq "M4 a repo wake does not move push" "$(rc_of rcm_moved o/r push 11 "$STAMP")" 1
eq "M4 quiet at the new mark" "$(rc_of rcm_moved o/r push,repo 12 "$STAMP")" 1
# M5
eq "M5 non-digit mark" "$(rc_of rcm_moved o/r push x12 "$STAMP")" 2
eq "M5 empty stamp" "$(rc_of rcm_moved o/r push 12 '')" 2
eq "M5 a mark above the mirror's wm" "$(rc_of rcm_moved o/r push 99 "$STAMP")" 2
eq "M5 a stamp before coverage" "$(rc_of rcm_moved o/r push 12 $((NOW - 86400)))" 2
# RCM_NOW is honoured only under HARNESS_TEST_SANDBOX=1 (bin/lib/repo-change-mark.sh _rcm_now);
# the CI test shards do not set it, so these two calls set it themselves.
eq "M5 a stamp past the horizon" "$(HARNESS_TEST_SANDBOX=1 RCM_NOW=$((NOW + 4 * 86400)) rc_of rcm_moved o/r push 12 "$STAMP")" 2
eq "M5 inside the horizon" "$(HARNESS_TEST_SANDBOX=1 RCM_NOW=$((NOW + 2 * 86400)) rc_of rcm_moved o/r push 12 "$STAMP")" 1
wf_stale
eq "M5 feed stale: mark" "$(rc_of rcm_mark o/r)" 2
eq "M5 feed stale: moved" "$(rc_of rcm_moved o/r push 12 "$STAMP")" 2
wf_fresh; wf_down
eq "M5 feed down: mark" "$(rc_of rcm_mark o/r)" 2
eq "M5 feed down: moved" "$(rc_of rcm_moved o/r push 12 "$STAMP")" 2
wf_up
eq "M5 feed back: quiet" "$(rc_of rcm_moved o/r push 12 "$STAMP")" 1
eq "M5 no harness root" "$( ( unset HARNESS H; rc_of rcm_mark o/r ) )" 2
# M6
[ "$(wf_calls)" -gt 0 ] && ok || bad "M6: the mirror never read the fixture feed"
M6_OTHER=$(grep -vE '^(JOBS GET /api/wakes\?|JOBS GET /api/settings|SUMMARY )' "$WF/calls.log")
[ -n "$M6_OTHER" ] && bad "M6: a worker read the fixture does not serve: $(head -3 <<<"$M6_OTHER")" || ok

echo "repo-change-mark: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/bin/bash
# tests/br-rebuild-gate-red.bh-8886-test.sh — the blocked resolver consumes a
# rebuild that ended GATE_RED.
#
# WHAT THIS IS ABOUT (BH-8886). A rebuild the resolver enqueued can end with the
# selection gate's `GATE_RED <n> red: <suites>; see <build>/gate.txt` (BH-8062)
# or the migration renumber's `GATE_RED migration-number: ...` (BH-7365). The
# gate pushed nothing, and a GATE_RED is not relaunched: it is a ticket-level
# stop, like PLAN_BLOCKED. br_rebuild_outcome had no GATE_RED case, so it
# answered "" and the resolver waited on "rebuild already in flight" every tick.
#
# MUTATIONS THAT MUST TURN THIS SUITE RED (checked 2026-11-03):
#   - remove the GATE_RED case in br_rebuild_outcome         -> B1 red
#   - map rebuild-gate-red to rebuild-fresh in br_action      -> B2 red
#
# Run from anywhere: bash tests/br-rebuild-gate-red.bh-8886-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The three br modules under test, sourced whole. br_row_closed beats through
# $H/bin/beat.sh, so a stub records every beat.
H="$T/h"
mkdir -p "$H/bin" "$T/rec"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
export BEAT_SINK="$T/beat.txt"
. "$DIR/bin/lib/br/discovery.sh" || exit 1
. "$DIR/bin/lib/br/ladder.sh" || exit 1
. "$DIR/bin/lib/br/record.sh" || exit 1

eq() { [ "$2" = "$3" ] && ok || bad "$1: expected '$3', got '$2'"; }

# ── B1 both GATE_RED shapes are the rebuild's own outcome ──────────────────
eq "B1 selection gate" "$(br_rebuild_outcome 'GATE_RED 7 red: tests/a.sh,tests/b.sh; see /x/gate.txt')" rebuild-gate-red
eq "B1 selection gate, one suite" "$(br_rebuild_outcome 'GATE_RED 1 red: tests/a.sh; see /x/gate.txt')" rebuild-gate-red
eq "B1 migration number" "$(br_rebuild_outcome 'GATE_RED migration-number: 0235 is taken on main by 0235_a.sql;')" rebuild-gate-red

# ── B2 the ladder abandons it, and the row close sends no beat ─────────────
eq "B2 br_action" "$(br_action rebuild-gate-red)" abandon-rebuild
eq "B2 br_reason_of" "$(br_reason_of 'rebuild-gate-red: GATE_RED 7 red: tests/a.sh')" rebuild-gate-red
eq "B2 br_reason_of bare" "$(br_reason_of rebuild-gate-red)" rebuild-gate-red
: > "$BEAT_SINK"
br_row_closed tproj BH-21 "$T/rec" https://github.com/o/r/pull/7 abandoned "rebuild ended GATE_RED" rebuild-gate-red
eq "B2 br_row_closed rc" "$?" 0
[ -s "$BEAT_SINK" ] && bad "B2 THE POINT: a rebuild's own GATE_RED writes no beat: $(cat "$BEAT_SINK")" || ok
# Control: the same call with an ordinary reason does beat, so the empty sink
# above is the guard, not a broken stub.
br_row_closed tproj BH-21 "$T/rec" https://github.com/o/r/pull/7 abandoned "x" build-dead
[ -s "$BEAT_SINK" ] && ok || bad "B2 control: an ordinary reason beats"

# ── B3 near misses keep their own words ────────────────────────────────────
eq "B3 PR_CREATED" "$(br_rebuild_outcome 'PR_CREATED https://github.com/o/r/pull/7')" rebuild-landed
eq "B3 PLAN_BLOCKED" "$(br_rebuild_outcome 'PLAN_BLOCKED x')" rebuild-plan-blocked
eq "B3 REVIEW_BLOCKED" "$(br_rebuild_outcome 'REVIEW_BLOCKED x')" rebuild-review-blocked
eq "B3 leading space" "$(br_rebuild_outcome ' GATE_RED x')" ""
eq "B3 RESULT_UNVERIFIED" "$(br_rebuild_outcome 'RESULT_UNVERIFIED GATE_RED x')" ""
eq "B3 SELECTION_GATE_RED" "$(br_rebuild_outcome 'SELECTION_GATE_RED: tests/a.sh')" ""

echo "br-rebuild-gate-red.bh-8886-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

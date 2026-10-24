#!/bin/bash
# tests/ready-queue-ts-lines-test.sh — a READY-QUEUE.log line written
# timestamp-first is still a live queue line.
#
# THE INCIDENT (project-3 TK-319, 2026-10-21/23). A triage session deferred TK-319
# and wrote `2026-10-21T23:38:59Z project-3 cmv6… TK-319 size=L … :: overlap-guard
# DEFER vs PR#550`. Every reader kept only `^[A-Z]+-[0-9]`, so the line was dead:
# no queue-pending gate, no queue scope, and TK-319 waited ~45 h for the daily
# full sweep. All 25 lines of that box's file had the shape.
#
# THE ROWS (N1-N4 fail on main):
#   N1  rq_lines returns a timestamp-first line, re-led by its key
#   N2  it gains project=<p> from the word after the timestamp, never twice
#   N3  rq_any is true for a file holding only such a line (the gate fires)
#   N4  rq_fp_file carries it (the fingerprint changes when it is added)
#   N5  key-first lines pass unchanged; comments, blanks, `[HOTFIX] …` and
#       key-less lines drop (only a TIMESTAMP-first line is re-led)
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ready-queue-ts-lines-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset HARNESS H HARNESS_CHECKOUT
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

R="$T/r"; mkdir -p "$R/logs"
export READY_QUEUE_ROWS=0 FLEET_CONF="$T/fleet.conf"
printf 'project-3 o/project-3 https://x /api/board 1 small 1.1.1.1\n' > "$FLEET_CONF"
# shellcheck source=bin/lib/ready-queue.sh
. "$DIR/bin/lib/ready-queue.sh" || { echo "FAIL: ready-queue.sh does not source"; exit 1; }
Q="$R/logs/READY-QUEUE.log"
TS='2026-10-21T23:38:59Z project-3 cmv6tq19g000m06l6gn9xughc TK-319 size=L kind=feature :: overlap-guard DEFER vs PR#550'

# --- N1 / N2 / N3 ------------------------------------------------------------
printf '%s\n' "$TS" > "$Q"
OUT=$(rq_lines "$R" "")
grep -q '^TK-319 ' <<<"$OUT" && ok || bad "N1 a timestamp-first line must come back re-led by its key (got: '$OUT')"
grep -q 'project=project-3' <<<"$OUT" && ok || bad "N2 the line must gain project=project-3 (got: '$OUT')"
[ "$(grep -o 'project=' <<<"$(printf '%s project=project-3\n' "$TS" | _rq_norm)" | wc -l | tr -d ' ')" = 1 ] && ok || bad "N2 an existing project= must not be added twice"
rq_any "$R" "" && ok || bad "N3 rq_any must be true for a file holding only a timestamp-first line"

# --- N4 ---------------------------------------------------------------------
printf 'TK-1 size=S :: x project=project-3\n' > "$Q"; A=$(rq_fp_file "$R" "")
printf '%s\n' "$TS" >> "$Q"; B=$(rq_fp_file "$R" "")
[ "$A" != "$B" ] && grep -q 'TK-319' <<<"$B" && ok || bad "N4 rq_fp_file must carry the timestamp-first line (got: '$B')"

# --- N5 ---------------------------------------------------------------------
OUT=$(printf '%s\n' '# header' '' 'no key at all here' '[HOTFIX] BH-1 1 — hot' '2026-10-21T23:38:59Z project-3 no key' 'TK-12 size=S :: gate project=project-3' | _rq_norm)
[ "$OUT" = 'TK-12 size=S :: gate project=project-3' ] && ok || bad "N5 key-first passes unchanged; comments, [HOTFIX] lines and key-less lines drop (got: '$OUT')"

echo "ready-queue-ts-lines-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]

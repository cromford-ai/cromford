#!/bin/bash
# tests/hosted-board-seams.bh-8918-test.sh — BH-8918: the hosted Board API's
# sources and the empty seams for later waves of BH-7913.
#   S1 every new source parses (node --check, bash -n, jq)
#   S2 each route seam exports an empty `routes` list and has no
#      test/route-table.d fragment, so ROUTES does not change
#   S3 the console seams export nothing and nothing imports them
#   S4 the board-intake lane: registered, gated, no cron fragment; its script
#      exits 0 with its one line, and exits 0 silently under its lane-off flag
#   S5 the jobs-client verb prints its usage, rc 2, on no subcommand
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/hosted-board-seams.bh-8918-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "SKIP: node or jq missing"; exit 0; }

JS_SOURCES=(
  "$REPO/worker/jobs/src/lib/hosted-board.js"
  "$REPO/worker/jobs/src/routes/hosted-board.js"
  "$REPO/worker/jobs/src/routes/hosted-board-admin.js"
  "$REPO/worker/jobs/src/routes/retention.d/bh-8918-hosted-board.js"
  "$REPO/worker/jobs/test/lib/d1-tx.bh-8918.js"
  "$REPO/tests/lib/hosted-board-worker.bh-8918.mjs"
)
ROUTE_SEAMS=(
  "$REPO/worker/jobs/src/routes/hosted-board-members.js"
  "$REPO/worker/jobs/src/routes/hosted-board-intake.js"
  "$REPO/worker/jobs/src/routes/hosted-board-webhooks.js"
)
UI_SEAMS=(
  "$REPO/console-ui/src/screens/Board.js"
  "$REPO/console-ui/src/screens/board/list-view.js"
  "$REPO/console-ui/src/screens/board/ticket-actions.js"
  "$REPO/console-ui/src/screens/board/members.js"
  "$REPO/console-ui/src/screens/board/intake.js"
)
SH_SOURCES=(
  "$REPO/bin/hosted-board-intake.sh"
  "$REPO/bin/jobs-client.d/bh-8918-hosted-board-token.sh"
  "$REPO/bin/lib/board-conformance/origin.sh"
)
LANE="$REPO/catalog/lanes.d/board-intake.json"

# S1
for f in "${JS_SOURCES[@]}" "${ROUTE_SEAMS[@]}" "${UI_SEAMS[@]}"; do
  [ -f "$f" ] || { bad "S1 missing $f"; continue; }
  node --check "$f" 2>"$T/err" && ok || bad "S1 node --check $f: $(cat "$T/err")"
done
for f in "${SH_SOURCES[@]}"; do
  [ -f "$f" ] || { bad "S1 missing $f"; continue; }
  bash -n "$f" 2>"$T/err" && ok || bad "S1 bash -n $f: $(cat "$T/err")"
done
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$REPO/bin/name-guard.py" && ok || bad "S1 bin/name-guard.py does not parse"
jq -e '.id == "board-intake"' "$LANE" >/dev/null && ok || bad "S1 $LANE is not the board-intake lane"

# S2
for f in "${ROUTE_SEAMS[@]}"; do
  fam=$(basename "$f" .js)
  n=$(node --input-type=module -e "const m = await import('file://$f'); process.stdout.write(String(Array.isArray(m.routes) ? m.routes.length : -1));" 2>"$T/err")
  [ "$n" = 0 ] && ok || bad "S2 $fam: routes is not an empty list (got [$n] $(cat "$T/err"))"
  frag=$(find "$REPO/worker/jobs/test/route-table.d" -name "*-$fam.txt" | wc -l)
  [ "$frag" -eq 0 ] && ok || bad "S2 $fam has a route-table fragment; a seam mounts nothing"
done

# S3
for f in "${UI_SEAMS[@]}"; do
  keys=$(node --input-type=module -e "const m = await import('file://$f'); process.stdout.write(String(Object.keys(m).length));" 2>"$T/err")
  [ "$keys" = 0 ] && ok || bad "S3 $f exports something ($keys) $(cat "$T/err")"
  b=$(basename "$f" .js)
  hits=$(grep -rlE "from ['\"][^'\"]*(screens/|/)board/$b(\.js)?['\"]|from ['\"][^'\"]*screens/Board(\.js)?['\"]" "$REPO/console-ui/src" 2>/dev/null | grep -v "^$f$" | grep -vc '^$')
  [ "$hits" -eq 0 ] && ok || bad "S3 $f is imported somewhere: a seam is not wired in this wave"
done

# S4
jq -e '.wired == true and .switch.name == "lane-off-board-intake" and .script == "bin/hosted-board-intake.sh" and (.cadence | test("no cron line"))' "$LANE" >/dev/null \
  && ok || bad "S4 the lane fragment is not the unscheduled, gated board-intake lane"
[ -z "$(find "$REPO/cron" -name '*board-intake*' 2>/dev/null)" ] && ok || bad "S4 a cron fragment schedules board-intake"
[ -x "$REPO/bin/hosted-board-intake.sh" ] && ok || bad "S4 bin/hosted-board-intake.sh is not executable"
H="$T/h"; mkdir -p "$H/flags" "$H/logs" "$H/state" "$H/catalog"
( cd "$REPO" && scratch_install_closure bin/hosted-board-intake.sh "$H" ) >/dev/null || bad "S4 cannot install the lane closure"
OUT=$(env -i PATH="$PATH" HOME="$T" HARNESS="$H" bash "$H/bin/hosted-board-intake.sh" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "hosted-board-intake: not built yet (wave 5)" ] && ok || bad "S4 lane on: rc $RC, out [$OUT]"
: > "$H/flags/lane-off-board-intake"
OUT=$(env -i PATH="$PATH" HOME="$T" HARNESS="$H" bash "$H/bin/hosted-board-intake.sh" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "S4 lane off: rc $RC, out [$OUT] (the gate must exit before the body)"

# S5
OUT=$(bash -c '. "$1"; jc_verb_hosted_board_token' _ "$REPO/bin/jobs-client.d/bh-8918-hosted-board-token.sh" 2>&1); RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in usage:*) true ;; *) false ;; esac && ok || bad "S5 no subcommand: rc $RC, out [$OUT]"

echo "hosted-board-seams.bh-8918: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo FAIL; exit 1; }
echo PASS

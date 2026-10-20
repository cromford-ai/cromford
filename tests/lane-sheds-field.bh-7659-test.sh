#!/bin/bash
# tests/lane-sheds-field.bh-7659-test.sh — BH-7659: every lane that
# bin/project-lane-run.sh dispatches and that starts agent or build work
# carries `"sheds"` in its catalog/lanes.d file. bin/lane-sheds-lint.sh is the
# checker; this suite runs it on the repo and on fixture trees.
#
#   L1 the repo is clean            L6 near misses are not flagged
#   L2 agent-call.sh, no field      L7 the live near misses carry no field
#   L3 cost_stage; a dispatch hop   L8 the catalog set = HLS_SPAWN_LANES
#   L4 sheds false needs a why      L9 a root with no catalog/lanes.d: rc 2
#   L5 sheds true, not dispatched
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-sheds-field.bh-7659-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
LINT="$REPO/bin/lane-sheds-lint.sh"
[ -s "$LINT" ] || { bad "missing bin/lane-sheds-lint.sh"; echo "lane-sheds-field: $PASS passed, $FAIL failed"; exit 1; }

# lint <root> — rc in $RC, stdout in $OUT
lint() { OUT=$(bash "$LINT" "$1" 2>"$T/lint.err"); RC=$?; }

# ══ L1: the repo ════════════════════════════════════════════════════════════
echo "L1 repo"
lint "$REPO"
check "L1 the repo: rc 0, no output (rc $RC: $OUT $(cat "$T/lint.err"))" '[ "$RC" = 0 ] && [ -z "$OUT" ]'

# fx <name> — a fresh fixture root; lane <id> <script-body> [extra jq object]
fx() { FX="$T/fx-$1"; mkdir -p "$FX/catalog/lanes.d" "$FX/bin"; }
lane() {
  printf '#!/bin/bash\n%s\n' "$2" > "$FX/bin/$1.sh"
  jq -n --arg id "$1" --argjson x "${3:-{\}}" '{id: $id, script: ("bin/" + $id + ".sh"), stats: {cost_stage: null}} * $x' \
    > "$FX/catalog/lanes.d/$1.json"
}
DISPATCH='say "$(pl_dispatch me 60 "$H/bin/me.sh")"'

# ══ L2: agent-call.sh with no field ═════════════════════════════════════════
echo "L2 missing field"
fx l2; lane spawner "$DISPATCH"$'\n''"$H/bin/agent-call.sh" triage x'
lint "$FX"
check "L2 a dispatched lane that calls agent-call.sh, no sheds: rc 1, one line naming it ($OUT)" \
  '[ "$RC" = 1 ] && [ "$(printf "%s\n" "$OUT" | grep -c .)" = 1 ] && [[ "$OUT" == *spawner* ]] && [[ "$OUT" == *agent-call.sh* ]]'
lane spawner "$DISPATCH"$'\n''"$H/bin/agent-call.sh" triage x' '{"sheds": true}'
lint "$FX"
check "L2 the same lane with sheds true: rc 0" '[ "$RC" = 0 ] && [ -z "$OUT" ]'

# ══ L3: cost_stage; a dispatch-line hop ═════════════════════════════════════
echo "L3 cost stage and hop"
fx l3a; lane coster "$DISPATCH" '{"stats": {"cost_stage": "x"}}'
lint "$FX"
check "L3 dispatched with cost_stage x, no sheds: rc 1 ($OUT)" '[ "$RC" = 1 ] && [[ "$OUT" == *coster* ]]'
fx l3b; lane hopper 'say "$(pl_dispatch hopper 60 "$H/bin/spawner.sh" --x)"'
printf '#!/bin/bash\n"$HARNESS/bin/run-build.sh" p 1 K\n' > "$FX/bin/spawner.sh"
lint "$FX"
check "L3 the dispatch line names bin/spawner.sh, which calls run-build.sh: rc 1 ($OUT)" '[ "$RC" = 1 ] && [[ "$OUT" == *hopper* ]]'
printf '#!/bin/bash\n# "$HARNESS/bin/run-build.sh" p 1 K\necho ok\n' > "$FX/bin/spawner.sh"
lint "$FX"
check "L3 the hop target names run-build.sh only in a comment: rc 0" '[ "$RC" = 0 ]'

# ══ L4: sheds false needs a reason; a string is not a boolean ═══════════════
echo "L4 sheds false and types"
fx l4; lane spawner "$DISPATCH"$'\n''claude-cost.sh x' '{"sheds": false}'
lint "$FX"
check "L4 sheds false, no sheds_why: rc 1 ($OUT)" '[ "$RC" = 1 ] && [[ "$OUT" == *sheds_why* ]]'
lane spawner "$DISPATCH"$'\n''claude-cost.sh x' '{"sheds": false, "sheds_why": "  "}'
lint "$FX"
check "L4 sheds false, blank sheds_why: rc 1" '[ "$RC" = 1 ]'
lane spawner "$DISPATCH"$'\n''claude-cost.sh x' '{"sheds": false, "sheds_why": "it clears the queue"}'
lint "$FX"
check "L4 sheds false with sheds_why: rc 0" '[ "$RC" = 0 ] && [ -z "$OUT" ]'
lane spawner "$DISPATCH"$'\n''claude-cost.sh x' '{"sheds": "true"}'
lint "$FX"
check "L4 sheds \"true\" (a string): rc 1 ($OUT)" '[ "$RC" = 1 ] && [[ "$OUT" == *boolean* ]]'

# ══ L5: sheds true on a lane project-lane-run never runs ════════════════════
echo "L5 not dispatched"
fx l5; lane hubby 'echo hub only' '{"sheds": true}'
lint "$FX"
check "L5 sheds true, not dispatched: rc 1 ($OUT)" '[ "$RC" = 1 ] && [[ "$OUT" == *hubby* ]]'

# ══ L6: near misses ═════════════════════════════════════════════════════════
echo "L6 near misses"
fx l6
lane commented "$DISPATCH"$'\n''  # starts "$H/bin/run-build.sh" one day'
lane namer "$DISPATCH"$'\n''echo "see bin/spawner.sh"'
printf '#!/bin/bash\n"$H/bin/agent-call.sh" x\n' > "$FX/bin/spawner.sh"
jq -n '{lib: "x", note: "calls bin/agent-call.sh", knobs: []}' > "$FX/catalog/lanes.d/_lib.x.json"
lane hubcost '"$H/bin/agent-call.sh" x' '{"stats": {"cost_stage": "y"}}'
lane reader "$DISPATCH"$'\n''jq . state.json'
lane shedonly "$DISPATCH" '{"shed": true}'
lint "$FX"
check "L6 comment marker, spawner named off a dispatch line, a _lib file, an undispatched cost lane, a read-only lane, a shed-only lane: rc 0 ($OUT)" \
  '[ "$RC" = 0 ] && [ -z "$OUT" ]'

# ══ L7: the live near misses ════════════════════════════════════════════════
echo "L7 live near misses"
for id in archie-fm pipeline-health pr-url-reconcile fleet-status-push; do
  f=$(grep -l "\"id\": \"$id\"" "$REPO"/catalog/lanes.d/*.json 2>/dev/null | head -1)
  check "L7 $id has a lane file and no sheds key" '[ -n "$f" ] && jq -e "has(\"sheds\") | not" "$f" >/dev/null'
done

# ══ L8: the catalog set equals the code fallback ════════════════════════════
echo "L8 catalog = HLS_SPAWN_LANES"
REGP=$(cd "$REPO" && env -u LANE_REGISTRY bash -c '. bin/lib/lanes-registry.sh && lanes_json_path "$PWD"' 2>/dev/null)
CAT=$(jq -r '.lanes[] | select(.sheds == true) | .id' "$REGP" 2>/dev/null | LC_ALL=C sort | paste -sd' ')
CODE=$( . "$REPO/bin/lib/hub-load-shed.sh"; printf '%s\n' $HLS_SPAWN_LANES | LC_ALL=C sort | paste -sd' ')
check "L8 sheds:true set = HLS_SPAWN_LANES ($CAT)" '[ -n "$CAT" ] && [ "$CAT" = "$CODE" ]'
check "L8 dequeue-watch: sheds false with a sheds_why" \
  'jq -e ".lanes[] | select(.id == \"dequeue-watch\") | .sheds == false and ((.sheds_why // \"\") | test(\"[^ ]\"))" "$REGP" >/dev/null 2>&1'

# ══ L9: bad roots ═══════════════════════════════════════════════════════════
echo "L9 bad root"
mkdir -p "$T/empty"; lint "$T/empty"
check "L9 a root with no catalog/lanes.d: rc 2" '[ "$RC" = 2 ]'
OUT=$(bash "$LINT" --nope 2>/dev/null); RC=$?
check "L9 an unknown flag: rc 2" '[ "$RC" = 2 ]'

echo
echo "lane-sheds-field: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

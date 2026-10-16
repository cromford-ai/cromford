#!/bin/bash
# tests/factory-stop-merge-deploy-tags.bh-3687-test.sh — the merge and deploy
# lanes carry their `factory_stop` tag (BH-3710, slice 2 of BH-3687).
#
# Against a registry rendered by the real bin/lanes-build.sh from the repo's
# real catalog/lanes.d, through a lane that sources the real
# bin/lib/lane-gate.sh (which sources the real bin/lib/factory-stop.sh):
#   T1 the `merge` set is exactly batch-resolve merge-conductor
#      merge-conductor-backstop merge-conductor-wake merge-queue rebase-train
#      repair-on-push (BH-6963: it pushes rebases to PR branches, as rebase-train
#      does; BH-6975: merge-conductor-wake starts keyed conductor ticks, as the
#      backstop does), and the `deploy` set
#      is exactly apply-migrations deploy-train fleet-propagate
#      migration-autopilot (the launch set belongs to its own slice);
#   T2 switch ON: each of the ten exits 0 before its sentinel, logs
#      `[lane-gate] <id>[/demo] SKIPPED — factory-stop (<tag> lane; ...)` and
#      posts a `paused` liveness; switch OFF: each runs; untagged real lanes
#      (review-prs, pipeline-health) run with the switch ON;
#   M1 (D1) rebase-train's tag stripped in a scratch lanes.d turns T1 red;
#   M2 (D1) deploy-train flipped to `merge` turns both T1 comparisons red.
# Header wiring of the ten real scripts to lane_gate_or_exit is pinned by
# tests/lanes-registry-test.sh section 5.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

MERGE_SET="batch-resolve merge-conductor merge-conductor-backstop merge-conductor-wake merge-queue rebase-train repair-on-push"
DEPLOY_SET="apply-migrations deploy-train fleet-propagate migration-autopilot"
NOW=1758300000
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog" "$T/src/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/factory-stop.sh" "$T/h/bin/lib/"

# The registry: the repo's real lanes, through the real composer.
cp -r "$DIR/catalog/lanes.d" "$T/src/catalog/"
"$DIR/bin/lanes-build.sh" --root "$T/src" --to "$T/h/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: setup: bin/lanes-build.sh could not render the registry"; exit 1; }

tagset() { jq -r --arg t "$2" '[.lanes[]|select(.factory_stop==$t)|.id]|sort|join(" ")' "$1"; }

# T1 — the rendered registry tags exactly these lanes.
eq "T1 merge set" "$(tagset "$T/h/catalog/lanes.json" merge)" "$MERGE_SET"
eq "T1 deploy set" "$(tagset "$T/h/catalog/lanes.json" deploy)" "$DEPLOY_SET"

# M1 / M2 (D1) — a scratch lanes.d with one tag stripped, or flipped, must
# change the comparisons T1 makes.
mutant() { # mutant <name> <lane> <jq filter> -> path of the mutant render
  local m="$T/$1"
  mkdir -p "$m/catalog"; cp -r "$DIR/catalog/lanes.d" "$m/catalog/"
  jq "$3" "$DIR/catalog/lanes.d/$2.json" > "$m/catalog/lanes.d/$2.json"
  "$DIR/bin/lanes-build.sh" --root "$m" --to "$m/lanes.json" >/dev/null 2>&1 || echo "FAIL-RENDER"
  echo "$m/lanes.json"
}
M1=$(mutant m1 rebase-train 'del(.factory_stop)')
[ "$(tagset "$M1" merge)" != "$MERGE_SET" ] && ok || bad "M1 T1 merge set stayed green with rebase-train untagged"
M2=$(mutant m2 deploy-train '.factory_stop="merge"')
[ "$(tagset "$M2" merge)" != "$MERGE_SET" ] && ok || bad "M2 T1 merge set stayed green with deploy-train flipped"
[ "$(tagset "$M2" deploy)" != "$DEPLOY_SET" ] && ok || bad "M2 T1 deploy set stayed green with deploy-train flipped"

cat > "$T/h/bin/fake-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/lib/lane-gate.sh"
lane_gate_or_exit "$LANE_ID" ${LANE_PROJECT:-}
echo SENTINEL
SH
chmod +x "$T/h/bin/fake-lane.sh"

# The stub client (as in tests/factory-stop-gate.bh-3687-test.sh): flag_sync
# answers rc 2 (no row); _jobs_req serves /api/settings from $ROWS_FILE and
# takes every POST. Every request is logged to $CALLS.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
flag_sync() { echo "flag_sync $1" >> "$CALLS"; return 2; }
_jobs_req() {
  echo "$1 $2 ${3:-}" >> "$CALLS"
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) printf '{}' ;;
  esac
}
SH

rows() { printf '[{"key":"switch.factory-stop","value":"%s","actor":"api"}]' "$1" > "$T/rows.json"; }
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"
  rm -f "$T/h/state/settings-cache.json" "$T/h/flags"/*
  : > "$T/calls"
}
run() { # run <lane id> -> stdout in OUT, exit code in RC; project lanes get "demo"
  local id="$1" proj=""
  [ "$(jq -r --arg i "$id" '.lanes[]|select(.id==$i)|.scope' "$T/h/catalog/lanes.json")" = project ] && proj=demo
  P="$proj"
  OUT=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      LANE_REGISTRY="$T/h/catalog/lanes.json" JOBS_BOX=b JOBS_URL=http://stub.invalid \
      LANE_ID="$id" LANE_PROJECT="$proj" "$T/h/bin/fake-lane.sh" 2>/dev/null); RC=$?
}
logged() { grep -qF -- "$1" "$T/h/logs/lane-gate.log" 2>/dev/null; }

# T2 ON — each tagged lane stops before its sentinel, naming its tag.
for tag in merge deploy; do
  set_ids=$MERGE_SET; [ "$tag" = deploy ] && set_ids=$DEPLOY_SET
  for id in $set_ids; do
    reset; rows 1
    run "$id"
    eq "T2 ON $id: output" "$OUT" ""
    eq "T2 ON $id: exit" "$RC" "0"
    logged "[lane-gate] $id${P:+/$P} SKIPPED — factory-stop ($tag lane; settings switch.factory-stop)" && ok \
      || bad "T2 ON $id: no SKIPPED line for a $tag lane: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"
    grep -q "^POST /api/lanes/liveness .*\"lane\":\"$id\".*\"outcome\":\"paused\"" "$T/calls" && ok \
      || bad "T2 ON $id: no paused liveness post: $(tr '\n' ' ' < "$T/calls")"
  done
done

# T2 OFF (M3) — the same ten run when the switch is OFF.
for id in $MERGE_SET $DEPLOY_SET; do
  reset; rows 0
  run "$id"
  eq "T2 OFF $id" "$OUT" "SENTINEL"
  logged "SKIPPED" && bad "T2 OFF $id: logged a SKIPPED line" || ok
done

# T2 negatives — untagged real lanes run with the switch ON.
for id in review-prs pipeline-health; do
  reset; rows 1
  run "$id"
  eq "T2 negative $id (untagged, switch ON)" "$OUT" "SENTINEL"
done

echo "factory-stop-merge-deploy-tags: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

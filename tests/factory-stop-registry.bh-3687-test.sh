#!/bin/bash
# tests/factory-stop-registry.bh-3687-test.sh — every lane the REAL registry
# tags with `factory_stop` is stopped by switch.factory-stop (BH-3709, slice 2
# of BH-3687).
#
# Generic over whatever catalog/lanes.d tags: the registry is rendered by the
# real bin/lanes-build.sh from the repo's manifests with no fixtures, and each
# tagged lane runs as its own process through a fake lane script that sources
# the real bin/lib/lane-gate.sh. Later slices that tag merge/deploy lanes join
# R1/R2/R4/R6 without an edit here.
#   R1 switch ON: every tagged lane exits 0 before its sentinel, logs
#      `[lane-gate] <id>[/<project>] ... SKIPPED — factory-stop` and stamps
#      state/lane-gate/<id>[-<project>].paused;
#   R2 switch OFF: every tagged lane runs;
#   R3 the 8 launch lanes are tagged `launch` and every tag value is one of
#      launch|merge|deploy; a registry with run-triage's tag removed, or
#      fly-pool's tag set to "stop", fails that check;
#   R4 no row: every tagged lane runs and the no-readable line is logged;
#   R5 switch ON: the monitoring lanes (pipeline-health, alert-digest,
#      jobs-watchdog, poll-commands, review-prs) still run;
#   R6 row values other than 1, and keys that only look like the switch, stop
#      nothing;
#   M1 (D1) a lane-gate.sh with the `# >>> factory stop` block deleted turns
#      R1 red.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

LG="${LG_UNDER_TEST:-$DIR/bin/lib/lane-gate.sh}"
NOW=1758300000
LAUNCH="run-triage preplan-tick blocked-resolver fix-round-claim fly-dispatch fly-pool-tick fly-pool prebuild-repro"
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog" "$T/src/catalog"
cp "$LG" "$T/h/bin/lib/lane-gate.sh"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/factory-stop.sh" "$T/h/bin/lib/"

# The registry: the repo's own manifests, no fixtures, through the real composer.
cp -r "$DIR/catalog/lanes.d" "$T/src/catalog/"
"$DIR/bin/lanes-build.sh" --root "$T/src" --to "$T/h/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: setup: bin/lanes-build.sh could not render the registry"; exit 1; }
REG="$T/h/catalog/lanes.json"
TAGGED=$(jq -r '.lanes[] | select(.factory_stop != null) | "\(.id) \(.scope)"' "$REG")
[ -n "$TAGGED" ] && ok || bad "setup: nothing in catalog/lanes.d is tagged factory_stop (R1/R2/R4/R6 would pass vacuously)"

cat > "$T/h/bin/fake-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/lib/lane-gate.sh"
lane_gate_or_exit "$LANE_ID" ${LANE_P:+"$LANE_P"}
echo SENTINEL
SH
chmod +x "$T/h/bin/fake-lane.sh"

# The stub client: flag_sync has no row (rc 2); _jobs_req serves /api/settings
# from $ROWS_FILE and takes every POST. Every request is logged to $CALLS.
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

rows() {
  local out='[]' kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]')
  done
  printf '%s' "$out" > "$T/rows.json"
}
# reset also wipes state/lane-gate, so the per-id log throttle never hides a line.
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"
  rm -f "$T/h/state/settings-cache.json" "$T/h/flags"/* "$T/rows.json"
  : > "$T/calls"
}
run() { # run <lane id> <scope> -> stdout in OUT, exit code in RC
  local id="$1" p=""
  [ "$2" = project ] && p=demo-project
  OUT=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      LANE_REGISTRY="$REG" JOBS_BOX=b JOBS_URL=http://stub.invalid \
      LANE_ID="$id" LANE_P="$p" "$T/h/bin/fake-lane.sh" 2>/dev/null); RC=$?
}
log() { cat "$T/h/logs/lane-gate.log" 2>/dev/null; }

# R1 — switch ON stops every tagged lane.
while read -r id scope; do
  [ -n "$id" ] || continue
  reset; rows switch.factory-stop=1
  run "$id" "$scope"
  eq "R1 $id switch ON: output" "$OUT" ""
  eq "R1 $id exit 0" "$RC" "0"
  log | grep -q "\[lane-gate\] ${id}[/ ].*SKIPPED — factory-stop" && ok \
    || bad "R1 $id no SKIPPED — factory-stop line: $(log)"
  ls "$T/h/state/lane-gate/$id"*.paused >/dev/null 2>&1 && ok \
    || bad "R1 $id no state/lane-gate/$id*.paused stamp"
done <<< "$TAGGED"

# R2 — switch OFF runs every tagged lane.
while read -r id scope; do
  [ -n "$id" ] || continue
  reset; rows switch.factory-stop=0
  run "$id" "$scope"
  eq "R2 $id switch OFF" "$OUT" "SENTINEL"
done <<< "$TAGGED"

# R3 — the launch set is tagged, every value is valid, and losing a tag is red.
check_tags() { # check_tags <registry> -> 0 when the launch set and every value hold
  local reg="$1" l
  for l in $LAUNCH; do
    [ "$(jq -r --arg l "$l" '.lanes[] | select(.id == $l) | .factory_stop // ""' "$reg")" = launch ] || return 1
  done
  [ "$(jq '[.lanes[] | .factory_stop // empty | select(IN("launch","merge","deploy") | not)] | length' "$reg")" = 0 ]
}
check_tags "$REG" && ok || bad "R3 the registry does not tag all of [$LAUNCH] launch, or carries a tag outside launch|merge|deploy: $(printf '%s' "$TAGGED" | tr '\n' ',')"
mutant_reg() { # mutant_reg <name> <manifest> <jq filter> -> path of a registry rendered from a mutated copy
  rm -rf "$T/$1"; mkdir -p "$T/$1/catalog"
  cp -r "$DIR/catalog/lanes.d" "$T/$1/catalog/"
  jq "$3" "$DIR/catalog/lanes.d/$2" > "$T/$1/catalog/lanes.d/$2"
  "$DIR/bin/lanes-build.sh" --root "$T/$1" --to "$T/$1.json" >/dev/null 2>&1 || echo "FAIL: setup: could not render $1" >&2
  echo "$T/$1.json"
}
check_tags "$(mutant_reg src2 run-triage.json 'del(.factory_stop)')" \
  && bad "R3 mutant: run-triage untagged still passes check_tags" || ok
check_tags "$(mutant_reg src3 fly-pool.json '.factory_stop = "stop"')" \
  && bad "R3 mutant: fly-pool tagged \"stop\" still passes check_tags" || ok

# R4 — no row: every tagged lane runs and says so.
while read -r id scope; do
  [ -n "$id" ] || continue
  reset; rows
  run "$id" "$scope"
  eq "R4 $id no row" "$OUT" "SENTINEL"
  log | grep -qF "factory-stop: no readable" && ok || bad "R4 $id the no-readable line was not logged"
done <<< "$TAGGED"

# R5 — monitoring is never stopped by the factory switch.
for m in pipeline-health:hub alert-digest:hub jobs-watchdog:box poll-commands:hub review-prs:project; do
  reset; rows switch.factory-stop=1
  run "${m%%:*}" "${m#*:}"
  eq "R5 ${m%%:*} switch ON" "$OUT" "SENTINEL"
  grep -q "SKIPPED" <<<"$(log)" && bad "R5 ${m%%:*} logged a SKIPPED line: $(log)" || ok
done

# R6 — only the exact row with value 1 stops anything.
while read -r id scope; do
  [ -n "$id" ] || continue
  for kv in "switch.factory-stop=yes" "switch.factory-stop=2" "switch.factory-stop=" \
            "switch.factory-stop= on" "switch.factory-stopped=1" "switch.factory-stop-x=1"; do
    reset; rows "$kv"
    run "$id" "$scope"
    eq "R6 $id row '$kv'" "$OUT" "SENTINEL"
  done
done <<< "$TAGGED"

# M1 (D1) — without the gate block, R1 goes red.
if [ -z "${LG_UNDER_TEST:-}" ]; then
  M="$T/mutant-lane-gate.sh"
  sed '/# >>> factory stop (BH-3687)/,/# <<< factory stop/d' "$LG" > "$M"
  if cmp -s "$M" "$LG"; then bad "M1 the block marker was not found"
  else
    MOUT=$(LG_UNDER_TEST="$M" HARNESS_TEST_SANDBOX=1 bash "$0" 2>&1)
    grep -q '^FAIL: R1' <<<"$MOUT" && ok || bad "M1 R1 stayed green without the block"
  fi
fi

echo "factory-stop-registry: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

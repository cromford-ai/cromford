#!/bin/bash
# tests/factory-stop-gate.bh-3687-test.sh — lane_gate_or_exit honours a lane
# manifest's `factory_stop` tag (BH-3708, slice 1 of BH-3687).
#
# What is proved here, through a real lane script that sources the real
# bin/lib/lane-gate.sh (which lazily sources the real bin/lib/factory-stop.sh)
# against a registry rendered by the real bin/lanes-build.sh from the repo's
# catalog/lanes.d plus fixture lanes:
#   G1 switch ON, a lane tagged "merge": no sentinel, exit 0, the SKIPPED line
#      names the tag and the row, the resume hint names the row,
#      state/lane-gate/<id>.paused exists, a `paused` liveness is posted;
#   G2 switch OFF -> the tagged lane runs;
#   G3 no row -> it runs, and the no-readable line is logged;
#   G4 switch ON, an untagged lane runs, never sources the lib and makes no
#      settings request;
#   G5 all-off wins with its own WHY;
#   G6 LANE_GATE_DISABLE=1 bypasses it;
#   G7 the lib missing (half-synced box) -> runs, with the missing-lib line;
#   G8 every factory_stop tag in catalog/lanes.d is launch|merge|deploy;
#   G9 a tag outside launch|merge|deploy is untagged;
#   M3 (D1) a lane-gate.sh with the `# >>> factory stop` block deleted turns
#      G1 red.
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
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog" "$T/src/catalog"
cp "$LG" "$T/h/bin/lib/lane-gate.sh"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/factory-stop.sh" "$T/h/bin/lib/"

# The registry: the repo's lanes plus three fixtures, through the real composer.
cp -r "$DIR/catalog/lanes.d" "$T/src/catalog/"
printf '{"id":"fs-tagged","scope":"hub","factory_stop":"merge"}\n' > "$T/src/catalog/lanes.d/fs-tagged.json"
printf '{"id":"fs-untagged","scope":"hub"}\n' > "$T/src/catalog/lanes.d/fs-untagged.json"
printf '{"id":"fs-badtag","scope":"hub","factory_stop":"yes"}\n' > "$T/src/catalog/lanes.d/fs-badtag.json"
"$DIR/bin/lanes-build.sh" --root "$T/src" --to "$T/h/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: setup: bin/lanes-build.sh could not render the fixture registry"; exit 1; }
eq "setup the fixture tag survives the composer" \
  "$(jq -r '.lanes[]|select(.id=="fs-tagged")|.factory_stop' "$T/h/catalog/lanes.json")" "merge"

cat > "$T/h/bin/fake-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/lib/lane-gate.sh"
lane_gate_or_exit "$LANE_ID"
declare -F factory_stopped >/dev/null && echo LIBLOADED
echo SENTINEL
SH
chmod +x "$T/h/bin/fake-lane.sh"

# The stub client: flag_sync drives all-off from $ALLOFF (rc 2 = no row
# otherwise); _jobs_req serves /api/settings from $ROWS_FILE and takes every
# POST. Every request is logged to $CALLS.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
flag_sync() {
  echo "flag_sync $1" >> "$CALLS"
  if [ "$1" = all-off ] && [ -n "${ALLOFF:-}" ]; then touch "$HARNESS/flags/all-off"; return 0; fi
  return 2
}
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
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"
  rm -f "$T/h/state/settings-cache.json" "$T/h/flags"/* "$T/rows.json"
  : > "$T/calls"
}
run() { # run <lane id> [env assignments...] -> stdout; RC holds the exit code
  local id="$1"; shift
  OUT=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      LANE_REGISTRY="$T/h/catalog/lanes.json" JOBS_BOX=b JOBS_URL=http://stub.invalid \
      LANE_ID="$id" "$@" "$T/h/bin/fake-lane.sh" 2>/dev/null); RC=$?
}
logged() { grep -qF -- "$1" "$T/h/logs/lane-gate.log" 2>/dev/null; }

# G1 — switch ON stops the tagged lane through the existing paused path.
reset; rows switch.factory-stop=1
run fs-tagged
eq "G1 tagged lane, switch ON: output" "$OUT" ""
eq "G1 exit 0" "$RC" "0"
logged "[lane-gate] fs-tagged SKIPPED — factory-stop (merge lane; settings switch.factory-stop)" && ok \
  || bad "G1 no SKIPPED line: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"
logged "set settings switch.factory-stop to 0 (PUT /api/settings) to resume" && ok \
  || bad "G1 the resume hint does not name the row"
[ -f "$T/h/state/lane-gate/fs-tagged.paused" ] && ok || bad "G1 no state/lane-gate/fs-tagged.paused"
grep -q '^POST /api/lanes/liveness .*"lane":"fs-tagged".*"outcome":"paused"' "$T/calls" && ok \
  || bad "G1 no paused liveness post: $(tr '\n' ' ' < "$T/calls")"

# G2 / G3 — OFF, or no row at all, runs it.
reset; rows switch.factory-stop=0
run fs-tagged
eq "G2 switch OFF" "$OUT" "LIBLOADED
SENTINEL"
reset; rows
run fs-tagged
eq "G3 no row" "$OUT" "LIBLOADED
SENTINEL"
logged "factory-stop: no readable switch.factory-stop row" && ok || bad "G3 the no-readable line was not logged"

# G4 — an untagged lane pays nothing, even with the switch ON.
reset; rows switch.factory-stop=1
run fs-untagged
eq "G4 untagged lane, switch ON" "$OUT" "SENTINEL"
eq "G4 no settings request" "$(grep -c '^GET /api/settings' "$T/calls")" "0"

# G5 — all-off is decided first and keeps its own WHY.
reset; rows switch.factory-stop=1
run fs-tagged ALLOFF=1
eq "G5 all-off: output" "$OUT" ""
logged "fs-tagged SKIPPED — all-off (fleet master switch)" && ok || bad "G5 all-off did not keep its WHY"
logged "SKIPPED — factory-stop" && bad "G5 factory-stop answered over all-off" || ok

# G6 — the escape hatch bypasses everything.
reset; rows switch.factory-stop=1
run fs-tagged LANE_GATE_DISABLE=1
eq "G6 LANE_GATE_DISABLE=1" "$OUT" "SENTINEL"

# G7 — a half-synced box with no lib runs the lane and says so.
reset; rows switch.factory-stop=1
mv "$T/h/bin/lib/factory-stop.sh" "$T/factory-stop.sh.away"
run fs-tagged
eq "G7 lib missing" "$OUT" "SENTINEL"
logged "factory-stop: bin/lib/factory-stop.sh missing (half-synced box) — read as NOT stopped" && ok \
  || bad "G7 the missing-lib line was not logged"
mv "$T/factory-stop.sh.away" "$T/h/bin/lib/factory-stop.sh"

# G8 — every real tag is a value the gate honours.
eq "G8 every real tag is launch|merge|deploy" \
  "$(cat "$DIR"/catalog/lanes.d/*.json | jq -s '[.[] | .factory_stop // empty | select(IN("launch","merge","deploy")|not)] | length')" "0"

# G9 — an unknown tag value is untagged, and said once.
reset; rows switch.factory-stop=1
run fs-badtag
eq "G9 tag 'yes' is untagged" "$OUT" "SENTINEL"
logged "fs-badtag" && ok || bad "G9 the unknown tag was not logged"

# M3 (D1) — without the block, G1 goes red.
if [ -z "${LG_UNDER_TEST:-}" ]; then
  M="$T/mutant-lane-gate.sh"
  sed '/# >>> factory stop (BH-3687)/,/# <<< factory stop/d' "$LG" > "$M"
  if cmp -s "$M" "$LG"; then bad "M3 the block marker was not found"
  else
    MOUT=$(LG_UNDER_TEST="$M" HARNESS_TEST_SANDBOX=1 bash "$0" 2>&1)
    grep -q '^FAIL: G1' <<<"$MOUT" && ok || bad "M3 G1 stayed green without the block"
  fi
fi

echo "factory-stop-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

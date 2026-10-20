#!/bin/bash
# tests/lane-load-shed.bh-7616-test.sh — lane_gate_or_exit sheds a lane whose
# manifest carries `"shed": true` while the hub load verdict (BH-7509) says
# over (BH-7616, slice C0).
#
# What is proved here, through a real lane script that sources the real
# bin/lib/lane-gate.sh (which lazily sources the real bin/lib/hub-load-shed.sh)
# against a registry rendered by the real bin/lanes-build.sh from the repo's
# catalog/lanes.d plus fixture lanes, with the verdict written by the real
# hls_write:
#   G1 tagged lane, verdict over: no sentinel, exit 0, the SKIPPED line and
#      resume hint, state/lane-gate/<id>.paused, a `paused` liveness post with
#      the why `load-shed p90=12 max=8 (shed lane)`;
#   G2 under, G3 insufficient, G4 stale, G5 shed=0, G6 malformed / no file:
#      the tagged lane runs;
#   G7 a string "true", 1, false or no tag: the lane runs while over;
#   G8 all-off wins with its own why;
#   G9 an untagged lane on a box with no verdict file never sources the lib;
#   G10 the real registry tags exactly ci-batch-ledger, issue-state-ledger,
#      orgo-state;
#   G11 no tagged lane carries factory_stop or names a merge, review, alert,
#      liveness or sampler lane;
#   G12 LANE_GATE_DISABLE=1 bypasses it;
#   G13 the lib missing (half-synced box): the lane runs, with the missing-lib
#      line;
#   M1 (D1) a lane-gate.sh with the `# >>> load shed` block deleted turns G1 red.
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

# The stub client goes in first: the closure install never overwrites it.
# flag_sync drives all-off from $ALLOFF (rc 2 = no row otherwise); _jobs_req
# answers every request. Every request is logged to $CALLS.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
flag_sync() {
  echo "flag_sync $1" >> "$CALLS"
  if [ "$1" = all-off ] && [ -n "${ALLOFF:-}" ]; then touch "$HARNESS/flags/all-off"; return 0; fi
  return 2
}
_jobs_req() {
  echo "$1 $2 ${3:-}" >> "$CALLS"
  case "$2" in
    /api/settings) printf '{"settings":[]}' ;;
    *) printf '{}' ;;
  esac
}
SH
scratch_install_closure bin/lib/lane-gate.sh "$T/h" >/dev/null || exit 1
# The verdict writer, from the repo, for the fixtures only.
# shellcheck source=../bin/lib/hub-load-shed.sh
. "$DIR/bin/lib/hub-load-shed.sh" || { echo "FAIL: setup: bin/lib/hub-load-shed.sh missing"; exit 1; }

# The registry: the repo's lanes plus five fixtures, through the real composer.
cp -r "$DIR/catalog/lanes.d" "$T/src/catalog/"
printf '{"id":"ls-tagged","scope":"hub","shed":true}\n'     > "$T/src/catalog/lanes.d/ls-tagged.json"
printf '{"id":"ls-string","scope":"hub","shed":"true"}\n'   > "$T/src/catalog/lanes.d/ls-string.json"
printf '{"id":"ls-one","scope":"hub","shed":1}\n'           > "$T/src/catalog/lanes.d/ls-one.json"
printf '{"id":"ls-false","scope":"hub","shed":false}\n'     > "$T/src/catalog/lanes.d/ls-false.json"
printf '{"id":"ls-untagged","scope":"hub"}\n'               > "$T/src/catalog/lanes.d/ls-untagged.json"
"$DIR/bin/lanes-build.sh" --root "$T/src" --to "$T/h/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: setup: bin/lanes-build.sh could not render the fixture registry"; exit 1; }
eq "setup the fixture tag survives the composer" \
  "$(jq -r '.lanes[]|select(.id=="ls-tagged")|.shed' "$T/h/catalog/lanes.json")" "true"

cat > "$T/h/bin/fake-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "${LG_UNDER_TEST:-$HARNESS/bin/lib/lane-gate.sh}"
lane_gate_or_exit "$LANE_ID"
declare -F hls_over >/dev/null && echo LIBLOADED
echo SENTINEL
SH
chmod +x "$T/h/bin/fake-lane.sh"

VF="$T/h/state/hub-load/verdict"
verdict() { # verdict <at> <p90> <state> <shed> — the real writer
  mkdir -p "$T/h/state/hub-load"
  hls_write "$VF" "$1" NA "$2" 8 "$3" 1800 "$4" || bad "setup: hls_write refused $*"
}
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/state/hub-load" "$T/h/logs/lane-gate.log"
  rm -f "$T/h/state/settings-cache.json" "$T/h/flags"/*
  : > "$T/calls"
}
run() { # run <lane id> [env assignments...] -> stdout; RC holds the exit code
  local id="$1"; shift
  OUT=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" HUB_LOAD_SHED_NOW="$NOW" CALLS="$T/calls" \
      LANE_REGISTRY="$T/h/catalog/lanes.json" JOBS_BOX=b JOBS_URL=http://stub.invalid \
      LANE_ID="$id" "$@" "$T/h/bin/fake-lane.sh" 2>/dev/null); RC=$?
}
logged() { grep -qF -- "$1" "$T/h/logs/lane-gate.log" 2>/dev/null; }
runs()   { eq "$1" "$OUT" "LIBLOADED
SENTINEL"; }

# G1 — over sheds the tagged lane through the existing paused path.
reset; verdict "$NOW" 12 over 1
run ls-tagged
eq "G1 tagged lane, over: output" "$OUT" ""
eq "G1 exit 0" "$RC" "0"
logged "[lane-gate] ls-tagged SKIPPED — load-shed p90=12 max=8 (shed lane)" && ok \
  || bad "G1 no SKIPPED line: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"
logged "runs again when state/hub-load/verdict is not over; settings hub_load.shed=off stops all shedding" && ok \
  || bad "G1 the resume hint does not name the verdict and the kill switch"
grep -qF "load-shed p90=12 max=8 (shed lane)" "$T/h/state/lane-gate/ls-tagged.paused" 2>/dev/null && ok \
  || bad "G1 no state/lane-gate/ls-tagged.paused with the why"
grep -q '^POST /api/lanes/liveness .*"lane":"ls-tagged".*"outcome":"paused"' "$T/calls" && ok \
  || bad "G1 no paused liveness post: $(tr '\n' ' ' < "$T/calls")"
grep -qF 'load-shed p90=12 max=8 (shed lane)' <(grep '^POST /api/lanes/liveness' "$T/calls") && ok \
  || bad "G1 the liveness post does not carry the why"

# G2-G6 — any verdict but a fresh over with shed=1 runs it.
reset; verdict "$NOW" 3 under 1;          run ls-tagged; runs "G2 under"
reset; verdict "$NOW" NA insufficient 1;  run ls-tagged; runs "G3 insufficient"
reset; verdict $((NOW - 1801)) 12 over 1; run ls-tagged; runs "G4 stale over"
reset; verdict "$NOW" 12 over 0;          run ls-tagged; runs "G5 shed=0 (kill switch)"
reset; mkdir -p "$T/h/state/hub-load"; printf 'garbage\n' > "$VF"
run ls-tagged; runs "G6 malformed line"
reset; run ls-tagged; eq "G6 no verdict file" "$OUT" "SENTINEL"
[ -f "$T/h/state/lane-gate/ls-tagged.paused" ] && bad "G6 a stamp was written for a lane that ran" || ok

# G7 — only the boolean true is a tag.
for id in ls-string ls-one ls-false ls-untagged; do
  reset; verdict "$NOW" 12 over 1; run "$id"; runs "G7 $id while over"
done

# G8 — an operator pause wins with its own why.
reset; verdict "$NOW" 12 over 1
run ls-tagged ALLOFF=1
eq "G8 all-off: output" "$OUT" ""
logged "ls-tagged SKIPPED — all-off (fleet master switch)" && ok || bad "G8 all-off did not keep its why"
logged "SKIPPED — load-shed" && bad "G8 load-shed answered over all-off" || ok

# G9 — no verdict file: an untagged lane never loads the reader.
reset; run ls-untagged
eq "G9 untagged, no verdict file" "$OUT" "SENTINEL"

# G10 — the real registry's shed set.
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/real.json" >/dev/null 2>&1 \
  || bad "G10 bin/lanes-build.sh could not render the repo registry"
eq "G10 the real shed lanes" \
  "$(jq -r '[.lanes[]|select(.shed==true)|.id]|sort|join(",")' "$T/real.json")" \
  "ci-batch-ledger,issue-state-ledger,orgo-state"

# G11 — never a merge, review, alert, liveness or sampler lane.
eq "G11 no tagged lane is a factory-stop lane" \
  "$(jq '[.lanes[]|select(.shed==true and .factory_stop!=null)]|length' "$T/real.json")" "0"
eq "G11 no tagged lane names a protected kind" \
  "$(jq -r '[.lanes[]|select(.shed==true)|.id|select(test("merge|review|alert|watchdog|reaper|heartbeat|liveness|probe|push|sample"))]|join(",")' "$T/real.json")" ""

# G12 — the escape hatch bypasses everything.
reset; verdict "$NOW" 12 over 1
run ls-tagged LANE_GATE_DISABLE=1
eq "G12 LANE_GATE_DISABLE=1" "$OUT" "SENTINEL"

# G13 — a half-synced box with no lib runs the lane and says so.
reset; verdict "$NOW" 12 over 1
mv "$T/h/bin/lib/hub-load-shed.sh" "$T/hub-load-shed.sh.away" 2>/dev/null
run ls-tagged
eq "G13 lib missing" "$OUT" "SENTINEL"
logged "load-shed: bin/lib/hub-load-shed.sh missing (half-synced box) — read as NOT over" && ok \
  || bad "G13 the missing-lib line was not logged"
mv "$T/hub-load-shed.sh.away" "$T/h/bin/lib/hub-load-shed.sh" 2>/dev/null

# M1 (D1) — without the block, G1 goes red. The fake lane sources the mutant
# from where it is: with the block gone, nothing reads a lib beside it.
if [ -z "${LG_UNDER_TEST:-}" ]; then
  M="$T/mutant-lane-gate.sh"
  sed '/# >>> load shed (BH-7616)/,/# <<< load shed/d' "$LG" > "$M"
  if cmp -s "$M" "$LG"; then bad "M1 the block marker was not found"
  else
    MOUT=$(LG_UNDER_TEST="$M" HARNESS_TEST_SANDBOX=1 bash "$0" 2>&1)
    grep -q '^FAIL: G1' <<<"$MOUT" && ok || bad "M1 G1 stayed green without the block"
  fi
fi

echo "lane-load-shed: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/lead-review-gate-record-fresh.bh-8349-test.sh — BH-8349: the
# gate-record check (lr_gate_record_mode, bin/lib/lead-review/gate-record.sh)
# reads its mode from the settings row lane.lead-review.lead_review_gate_record
# AT THE CALL, through lane_knob, not only from the env value lane_env_apply
# exported at tick start. A row set after the request was queued applies to
# the review that runs.
#   G1  env LEAD_REVIEW_GATE_RECORD=block and a lane_knob that answers note:
#       note; lane_knob is asked for lead-review LEAD_REVIEW_GATE_RECORD
#   G2  no lane_knob loaded: the env value (off -> off, junk -> block, unset -> block)
#   G3  the real bin/lib/lane-gate.sh: env block, a fresh settings cache row
#       note -> note; the row removed -> block (the env value); a junk row -> block
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-gate-record-fresh.bh-8349-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset LEAD_REVIEW_GATE_RECORD

H="$T/h"; mkdir -p "$H/state"
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || { echo "closure install of bin/lead-review.sh failed"; exit 1; }
MOD="$H/bin/lib/lead-review/gate-record.sh"
[ -r "$MOD" ] || { echo "setup: the closure carries no bin/lib/lead-review/gate-record.sh"; exit 1; }

# ── G1: a lane_knob answer wins over the env value ──
got=$( export LEAD_REVIEW_GATE_RECORD=block
  lane_knob() { printf '%s %s\n' "$*" >> "$T/knob-args"; printf note; }
  . "$MOD" || exit 9; lr_gate_record_mode )
[ "$got" = note ] && ok || bad "G1 want note from the settings row, got '$got'"
[ "$(cat "$T/knob-args" 2>/dev/null)" = "lead-review LEAD_REVIEW_GATE_RECORD " ] \
  && ok || bad "G1 lane_knob must be asked for lead-review LEAD_REVIEW_GATE_RECORD: '$(cat "$T/knob-args" 2>/dev/null)'"
got=$( lane_knob() { printf 'not-a-mode'; }; . "$MOD" || exit 9; LEAD_REVIEW_GATE_RECORD=note lr_gate_record_mode )
[ "$got" = block ] && ok || bad "G1b a junk knob answer is block, got '$got'"

# ── G2: no lane_knob: the env value, as before ──
g2() { ( unset -f lane_knob; . "$MOD" || exit 9; if [ "$#" -ge 1 ]; then export LEAD_REVIEW_GATE_RECORD="$1"; fi; lr_gate_record_mode ); }
[ "$(g2 off)" = off ] && ok || bad "G2 env off -> off, got '$(g2 off)'"
[ "$(g2 junk)" = block ] && ok || bad "G2 env junk -> block, got '$(g2 junk)'"
[ "$(g2)" = block ] && ok || bad "G2 unset -> block, got '$(g2)'"

# ── G3: the real lane_knob over a settings cache ──
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "setup: lanes-build.sh could not compose the registry"
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$H/state/settings-cache.json"
  scratch_rm "$H/state/lane-gate"; }
g3() { ( export HARNESS="$H" LANE_REGISTRY="$REG" JOBS_URL='' LEAD_REVIEW_GATE_RECORD=block
  . "$H/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 9; . "$MOD" || exit 9; lr_gate_record_mode ) 2>/dev/null; }
cache '{"lane.lead-review.lead_review_gate_record":"note"}'
[ "$(g3)" = note ] && ok || bad "G3 a fresh settings row note must win over env block, got '$(g3)'"
cache '{}'
[ "$(g3)" = block ] && ok || bad "G3 no row: the env value block, got '$(g3)'"
cache '{"lane.lead-review.lead_review_gate_record":"maybe"}'
[ "$(g3)" = block ] && ok || bad "G3 a junk row is block, got '$(g3)'"

echo "lead-review-gate-record-fresh.bh-8349: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

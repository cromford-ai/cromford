#!/bin/bash
# tests/lead-gates-knobs-moved.bh-5878-test.sh — BH-5878: the enqueue
# lane's gate knobs are the lead-review lane's now (catalog/lanes.d/
# lead-review.knobs.d/), and the worklist gates read them there. The registry
# is the repo's own catalog/lanes.d, composed in a scratch harness by
# bin/lib/lanes-registry.sh, with a settings cache the test writes.
#   K1  `lane_env_apply lead-review` exports LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=15
#       (required), and lane_knob lead-review reads every moved knob at its
#       default; lgk_load gives LGK_MAXT=15 and the gate defaults.
#   K2  a row lane.lead-review.lead_review_require_builder_approve=1 gives
#       _LGB_REQB=1 (lg_tick_builder); the same row under the old lane
#       lead-review-enqueue gives 0. A row lane.lead-review.pr_self_check=0
#       reaches lane_knob lead-review PR_SELF_CHECK.
#   K3  no lead-review-enqueue lane in the registry: lgk_load still gives
#       LGK_MAXT=15.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-knobs-moved.bh-5878-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin" "$H/state" "$H/catalog"
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || { echo "FAIL: closure install of bin/lead-review.sh"; exit 1; }
cp -R "$DIR/catalog/lanes.d" "$H/catalog/"
# bin/lib/lanes-registry.sh composes catalog/lanes.json with bin/lanes-build.sh.
cp "$DIR/bin/lanes-build.sh" "$H/bin/"
scratch_install_closure bin/lanes-build.sh "$H" >/dev/null || { echo "FAIL: closure install of bin/lanes-build.sh"; exit 1; }
[ -r "$H/bin/lib/lead-gates-knobs.sh" ] && [ -r "$H/bin/lib/lead-gates.d/10-builder.sh" ] && ok || bad "setup: the gate libs are not installed"
NOW=1792000000
# settings <json object of rows> — a fresh settings cache, so no worker is asked
settings() { jq -nc --argjson v "$1" --argjson t "$NOW" '{fetched_at:$t, values:$v}' > "$H/state/settings-cache.json"; }
# run <script> — the script in a clean shell against the scratch harness
run() {
  env -i PATH="$PATH" HOME="$T" TMPDIR="$T" HARNESS="$H" LANE_GATE_NOW="$NOW" LANE_GATE_CACHE_S=600 JOBS_URL=https://jobs.invalid \
    ${EXTRA:-} bash -c ". \"$H/bin/lib/lane-gate.sh\" || exit 9; $1" 2>"$T/err"
}

# ── K1: the moved knobs resolve under lead-review at their defaults ──
settings '{}'
got=$(run 'lane_env_apply lead-review >/dev/null 2>&1 || echo "rc $?"; printf "%s" "${LEAD_REVIEW_ENQUEUE_MAX_PER_TICK:-unset}"')
[ "$got" = 15 ] && ok || bad "K1 lane_env_apply lead-review exported LEAD_REVIEW_ENQUEUE_MAX_PER_TICK='$got' (want 15): $(cat "$T/err")"
while IFS='=' read -r k want; do
  got=$(run "lane_knob lead-review $k")
  [ "$got" = "$want" ] && ok || bad "K1 lane_knob lead-review $k='$got' (want '$want')"
done <<'EOF'
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=15
LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=0
LEAD_REVIEW_FAILED_RETRY_MAX=2
LEAD_REVIEW_TRACED_WAIT=1
LEAD_REVIEW_TRACED_JOB=Tests, traced
LEAD_REVIEW_TRACED_MAX_WAIT_MIN=30
LEAD_REVIEW_TRACED_WORKFLOW=harness-ci.yml
LEAD_REVIEW_REBASE_HOLD=1
LEAD_REVIEW_SILENCE_CHECK=1
PR_SELF_CHECK=1
PR_SELF_CHECK_MAX_WAIT_MIN=30
LEAD_REVIEW_PROBE_WAIT_MAX_MIN=60
EOF
got=$(run ". \"$H/bin/lib/lead-gates-knobs.sh\"; lgk_load; printf '%s|%s|%s|%s' \"\$LGK_RC\" \"\$LGK_MAXT\" \"\$LGK_RETRYMAX\" \"\$LGK_TMAX\"")
[ "$got" = "0|15|2|30" ] && ok || bad "K1 lgk_load rc|maxt|retry|tmax='$got' (want 0|15|2|30): $(cat "$T/err")"

# ── K2: a lead-review row drives the gates; an old-lane row does not ──
B10=". \"$H/bin/lib/lead-gates.sh\"; _lgt_load >/dev/null 2>&1; lg_tick_builder x/y; printf '%s' \"\$_LGB_REQB\""
settings '{"lane.lead-review.lead_review_require_builder_approve":"1"}'
got=$(run "$B10")
[ "$got" = 1 ] && ok || bad "K2 _LGB_REQB='$got' with the lead-review row (want 1): $(cat "$T/err")"
settings '{"lane.lead-review-enqueue.lead_review_require_builder_approve":"1"}'
got=$(run "$B10")
[ "$got" = 0 ] && ok || bad "K2 _LGB_REQB='$got' with only the old-lane row (want 0)"
settings '{"lane.lead-review.pr_self_check":"0"}'
got=$(run 'lane_knob lead-review PR_SELF_CHECK')
[ "$got" = 0 ] && ok || bad "K2 lane_knob lead-review PR_SELF_CHECK='$got' with the row (want 0)"
settings '{}'
got=$(EXTRA="LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1" run "$B10")
[ "$got" = 1 ] && ok || bad "K2 _LGB_REQB='$got' with the env 1 (want 1)"

# ── K3: no enqueue lane: the gates still read 15 ──
rm -f "$H/catalog/lanes.d/lead-review-enqueue.json" "$H/catalog/lanes.json"
settings '{}'
got=$(run ". \"$H/bin/lib/lead-gates-knobs.sh\"; lgk_load; printf '%s|%s' \"\$LGK_RC\" \"\$LGK_MAXT\"")
[ "$got" = "0|15" ] && ok || bad "K3 lgk_load rc|maxt='$got' with no enqueue lane (want 0|15): $(cat "$T/err")"

echo "lead-gates-knobs-moved.bh-5878: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

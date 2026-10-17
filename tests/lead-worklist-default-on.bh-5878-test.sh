#!/bin/bash
# tests/lead-worklist-default-on.bh-5878-test.sh — BH-5878 (slice C0): the
# needs-review worklist of bin/lead-review.sh is on by default. The gates of
# bin/lead-review-enqueue.sh have a home in bin/lib/lead-gates.d/, so an unset
# LEAD_REVIEW_WORKLIST reads the worklist, and a settings row
# lane.lead-review.lead_review_worklist=0 turns it off. The enqueue still runs
# next to it: a head it already requested is reviewed once. D1-D3, D5 and M1
# drive bin/lead-review.sh tick WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh.
#   D1  LEAD_REVIEW_WORKLIST unset, one ready head: one needs-review read, one
#       /start, one lead_review job, one agent call.
#   D2  LEAD_REVIEW_WORKLIST=0: no needs-review read, no /start, no job.
#   D3  the head already has a `requested` row by lead-review-enqueue:hub: the
#       row is claimed by id and reviewed once; no /start, one job.
#   D4  the lead-review lane's registry default (catalog/lanes.d/lead-review.json)
#       is 1: lane_knob lead-review LEAD_REVIEW_WORKLIST reads 1 with no row (the
#       knob is not required, so lane_env_apply exports nothing and the code
#       fallback `:-1` is what runs). A row lane.lead-review.lead_review_worklist=0
#       reads 0 and lane_env_apply exports it.
#   D5  LEAD_REVIEW_WORKLIST=yes: no worklist, and one log line names the value.
#   M1  a mutation: with the code fallback back at `:-0`, D1 starts nothing.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-worklist-default-on.bh-5878-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
starts() { lwf_cnt '^POST /api/lead-reviews/start ' "$T/log/worker"; }
needs_reads() { lwf_cnt '^GET /api/pr-state/needs-review' "$T/log/worker"; }
# tick_unset — one tick with LEAD_REVIEW_WORKLIST unset (the fixture exports 1)
tick_unset() { ( unset LEAD_REVIEW_WORKLIST; LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick; exit "$RC" ); RC=$?; }

# ── D1: unset = on: the ready head starts ──
lwf_reset
lwf_needs example-org/demo-os 101
tick_unset
[ "$RC" -eq 0 ] && ok || bad "D1 rc=$RC $(cat "$T/out")"
[ "$(needs_reads)" = 1 ] && ok || bad "D1 needs-review reads=$(needs_reads) (want 1): $(cat "$L" 2>/dev/null)"
[ "$(starts)" = 1 ] && ok || bad "D1 /start calls=$(starts) (want 1)"
[ "$(lwf_agents)" = 1 ] && ok || bad "D1 agent calls=$(lwf_agents) (want 1)"
[ "$(lwf_cnt '^POST /api/jobs .*"kind":"lead_review"' "$T/log/worker")" = 1 ] && ok || bad "D1 lead_review job opens=$(lwf_cnt '^POST /api/jobs .*"kind":"lead_review"' "$T/log/worker") (want 1)"

# ── D2: 0 = off ──
lwf_reset
lwf_needs example-org/demo-os 101
LEAD_REVIEW_WORKLIST=0 LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick
[ "$(needs_reads)" = 0 ] && ok || bad "D2 needs-review reads=$(needs_reads) with LEAD_REVIEW_WORKLIST=0"
[ "$(starts)" = 0 ] && ok || bad "D2 /start calls=$(starts) with LEAD_REVIEW_WORKLIST=0"
[ "$(lwf_agents)" = 0 ] && ok || bad "D2 agent calls=$(lwf_agents) (want 0)"

# ── D3: the enqueue's request row for the same head: reviewed once ──
lwf_reset
lwf_needs example-org/demo-os 101
jq -nc --arg s "$SHA" '[{id:"r-101", repo:"example-org/demo-os", pr:101, head_sha:$s, status:"requested",
  created_at:"2026-10-10 03:00:00", scope_notes:"auto: builder APPROVE", requested_by:"lead-review-enqueue:hub"}]' > "$FX/rows.json"
tick_unset
[ "$(lwf_cnt '^POST /api/lead-reviews/r-101/claim' "$T/log/worker")" = 1 ] && ok || bad "D3 r-101 claims=$(lwf_cnt '^POST /api/lead-reviews/r-101/claim' "$T/log/worker") (want 1): $(cat "$L")"
[ "$(starts)" = 0 ] && ok || bad "D3 /start calls=$(starts) (want 0: the row is the claim)"
[ "$(lwf_agents)" = 1 ] && ok || bad "D3 agent calls=$(lwf_agents) (want 1)"
[ "$(lwf_cnt '^POST /api/jobs .*"kind":"lead_review"' "$T/log/worker")" = 1 ] && ok || bad "D3 lead_review job opens=$(lwf_cnt '^POST /api/jobs .*"kind":"lead_review"' "$T/log/worker") (want 1)"

# ── D4: the registry default is 1; a settings row turns it off ──
R="$T/reg"; mkdir -p "$R/bin" "$R/state" "$R/catalog"
scratch_install_closure bin/lead-review.sh "$R" >/dev/null || bad "D4 closure install of bin/lead-review.sh"
cp -R "$SRC/catalog/lanes.d" "$R/catalog/"
cp "$SRC/bin/lanes-build.sh" "$R/bin/"
scratch_install_closure bin/lanes-build.sh "$R" >/dev/null || bad "D4 closure install of bin/lanes-build.sh"
NOW=1792000000
# regread <settings json> — "<lane_knob value>|<env after lane_env_apply>"
regread() {
  jq -nc --argjson v "$1" --argjson t "$NOW" '{fetched_at:$t, values:$v}' > "$R/state/settings-cache.json"
  env -i PATH="$PATH" HOME="$T" TMPDIR="$T" HARNESS="$R" LANE_GATE_NOW="$NOW" LANE_GATE_CACHE_S=600 JOBS_URL=https://jobs.invalid \
    bash -c ". \"$R/bin/lib/lane-gate.sh\" || exit 9; k=\$(lane_knob lead-review LEAD_REVIEW_WORKLIST)
      lane_env_apply lead-review >/dev/null 2>&1; printf '%s|%s' \"\$k\" \"\${LEAD_REVIEW_WORKLIST-unset}\"" 2>"$T/reg.err"
}
got=$(regread '{}')
[ "$got" = "1|unset" ] && ok || bad "D4 no row: knob|env='$got' (want 1|unset): $(cat "$T/reg.err")"
got=$(regread '{"lane.lead-review.lead_review_worklist":"0"}')
[ "$got" = "0|0" ] && ok || bad "D4 the row =0: knob|env='$got' (want 0|0): $(cat "$T/reg.err")"

# ── D5: a junk value: no worklist, one log line ──
lwf_reset
lwf_needs example-org/demo-os 101
LEAD_REVIEW_WORKLIST=yes LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick
[ "$(needs_reads)" = 0 ] && ok || bad "D5 needs-review reads=$(needs_reads) with LEAD_REVIEW_WORKLIST=yes"
[ "$(grep -c "LEAD_REVIEW_WORKLIST='yes' is not 0 or 1" "$L" 2>/dev/null)" = 1 ] && ok || bad "D5 log lines for the junk value: $(cat "$L" 2>/dev/null)"

# ── M1: a mutation: the code fallback back at 0 ──
cp "$H/bin/lead-review.sh" "$T/lead-review.sh.keep"
sed -i 's/\${LEAD_REVIEW_WORKLIST:-1}/${LEAD_REVIEW_WORKLIST:-0}/' "$H/bin/lead-review.sh"
if cmp -s "$H/bin/lead-review.sh" "$T/lead-review.sh.keep"; then
  bad "M1 the mutation changed nothing: no \${LEAD_REVIEW_WORKLIST:-1} in bin/lead-review.sh"
else
  lwf_reset
  lwf_needs example-org/demo-os 101
  tick_unset
  [ "$(starts)" = 0 ] && ok || bad "M1 with the fallback at 0 the unset tick still started $(starts) (the default is not the fallback's)"
fi
cp "$T/lead-review.sh.keep" "$H/bin/lead-review.sh"

echo "lead-worklist-default-on.bh-5878: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

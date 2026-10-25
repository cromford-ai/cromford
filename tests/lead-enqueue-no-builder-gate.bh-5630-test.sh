#!/bin/bash
# tests/lead-enqueue-no-builder-gate.bh-5630-test.sh — one review gate: the
# builder gate on the worklist, gate 1, bin/lib/lead-gates.d/10-builder.sh, and
# the skip ledger (05-skip-ledger.sh). A head with green CI gets a lead_review
# job even when no builder APPROVE is bound to that head.
# bin/lead-review.sh tick runs WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh (LEAD_REVIEW_WORKLIST=1).
#   D1  a builder BLOCK on the head, CI green: no lead_review job, no agent
#       call, one `[skip builder-block]` line naming #101.
#   D1b the same head on a second tick: still one `[skip builder-block]` line.
#   D2  no builder row, the knob unset (reads as 0), CI green: one job.
#   D3  no builder row, CI not green: no job, held=1, one `CI not known green` line.
#   D4  the builder ledger answers 500: no job, held=1.
#   D5  no builder row, LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1: one `[skip
#       no-approve]` line, no job, no check-run read.
#   D6  a builder APPROVE on an earlier head, head-bound reapproved@head: one
#       job, no check-run read. D6b the APPROVE on an earlier head, no rebind,
#       CI green: one job.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-no-builder-gate.bh-5630-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
[ -r "$H/bin/lib/lead-gates.d/05-skip-ledger.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/05-skip-ledger.sh"
[ -r "$H/bin/lib/lead-gates.d/10-builder.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/10-builder.sh"
djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
dskip() { lwf_cnt "\[skip $1\] example-org/demo-os#$2 @${SHA:0:12} " "$L"; }
dchecks() { lwf_cnt "commits/.*/check-runs" "$T/log/gh"; }

# ── D1 / D1b: a builder BLOCK with CI green does not start a review ──
lwf_reset; lwf_needs example-org/demo-os 101; lwf_ci_green "$SHA"; lwf_bv 101 BLOCK "$SHA"
lwf_tick
[ "$(djobs 101)" = 0 ] && ok || bad "D1 lead_review jobs for 101=$(djobs 101) (want 0): $(cat "$L")"
[ "$(lwf_agents)" = 0 ] && ok || bad "D1 agent calls=$(lwf_agents)"
[ "$(dskip builder-block 101)" = 1 ] && ok || bad "D1 [skip builder-block] lines=$(dskip builder-block 101): $(cat "$L")"
[[ "$(lwf_summary)" == *" skipped=1 "* ]] && ok || bad "D1 summary: $(lwf_summary)"
lwf_tick
[ "$(dskip builder-block 101)" = 1 ] && ok || bad "D1b [skip builder-block] lines after 2 ticks=$(dskip builder-block 101)"
[ "$(djobs 101)" = 0 ] && ok || bad "D1b jobs=$(djobs 101)"

# ── D2: no builder row, knob unset, CI green: one review ──
lwf_reset; lwf_needs example-org/demo-os 102; lwf_ci_green "$SHA"; : > "$FX/bv.102.none"
lwf_tick
[ "$(djobs 102)" = 1 ] && ok || bad "D2 jobs for 102=$(djobs 102) (want 1): $(cat "$L")"
[ "$(dchecks)" -ge 1 ] && ok || bad "D2 no check-run read"

# ── D3: no builder row, CI not green: held ──
lwf_reset; lwf_needs example-org/demo-os 103; : > "$FX/bv.103.none"
printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "Tests"\n' > "$FX/mergify.yml"
lwf_tick
[ "$(djobs 103)" = 0 ] && ok || bad "D3 jobs for 103=$(djobs 103) (want 0)"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "D3 summary: $(lwf_summary)"
[ "$(lwf_cnt "example-org/demo-os#103 @${SHA:0:12}: no builder APPROVE on this head and CI not known green (required not green: Tests); held" "$L")" = 1 ] \
  && ok || bad "D3 no CI-not-green line: $(cat "$L")"

# ── D4: the builder ledger unreadable: held, never 'no builder row' ──
lwf_reset; lwf_needs example-org/demo-os 104; lwf_ci_green "$SHA"; : > "$FX/bv.104.fail"
lwf_tick
[ "$(djobs 104)" = 0 ] && ok || bad "D4 jobs for 104=$(djobs 104) (want 0)"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "D4 summary: $(lwf_summary)"
grep -q "example-org/demo-os#104 @${SHA:0:12}: builder verdict unreadable (rc 1); held" "$L" && ok || bad "D4 no unreadable line: $(cat "$L")"

# ── D5: the builder gate on (REQB=1): skipped, no CI read ──
lwf_reset; lwf_needs example-org/demo-os 105; lwf_ci_green "$SHA"; : > "$FX/bv.105.none"
LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 lwf_tick
[ "$(djobs 105)" = 0 ] && ok || bad "D5 jobs for 105=$(djobs 105) (want 0)"
[ "$(dskip no-approve 105)" = 1 ] && ok || bad "D5 [skip no-approve] lines=$(dskip no-approve 105): $(cat "$L")"
[ "$(dchecks)" = 0 ] && ok || bad "D5 check-run reads=$(dchecks) (want 0)"

# ── D6 / D6b: an APPROVE on an earlier head ──
OLD=$(printf '%040d' 5)
lwf_reset; lwf_needs example-org/demo-os 106; lwf_bv 106 APPROVE "$OLD" "reapproved@$SHA"
lwf_tick
[ "$(djobs 106)" = 1 ] && ok || bad "D6 jobs for 106=$(djobs 106) (want 1): $(cat "$L")"
[ "$(dchecks)" = 0 ] && ok || bad "D6 a rebound head read check runs ($(dchecks))"
lwf_reset; lwf_needs example-org/demo-os 106; lwf_bv 106 APPROVE "$OLD"; lwf_ci_green "$SHA"
lwf_tick
[ "$(djobs 106)" = 1 ] && ok || bad "D6b jobs for 106=$(djobs 106) (want 1): $(cat "$L")"
lwf_reset; lwf_needs example-org/demo-os 106; lwf_bv 106 APPROVE "$OLD"
lwf_tick
[ "$(djobs 106)" = 0 ] && [[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "D6c an earlier APPROVE without green CI started: $(lwf_summary)"

echo "lead-enqueue-no-builder-gate.bh-5630: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

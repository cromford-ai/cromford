#!/bin/bash
# tests/lead-review-enqueue-authors.bh-5351-test.sh — the head-authors job field
# on the worklist: gate 14, bin/lib/lead-gates.d/25-authors.sh.
# bin/lead-review.sh tick runs WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh; the head ref comes from the PR
# body gate 55 (55-snapshot.sh) read. The rules DA1-DA3 do not pin (trim,
# lowercase, the ticket-key bound, truncation, participant, the cap of 16) are
# in tests/lead-gates-authors.bh-7236-test.sh.
#   DA1 the build job names box-a, a fix round with cap_key demo-os-BH-12 was
#       claimed by box-b, the PR head ref is ticket/bh-12: the lead_review
#       job's meta.head_authors holds box-a and box-b.
#   DA2 the fix-round reads answer 500: the job still opens, head_authors
#       holds box-a, and the log names the failure.
#   DA3 no identity at all: the job opens with no head_authors key, and the
#       log says why.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue-authors.bh-5351-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
[ -r "$H/bin/lib/lead-gates.d/25-authors.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/25-authors.sh"
# job_meta — the meta object of the one lead_review job POST for #101
job_meta() { grep '^POST /api/jobs .*"ticket_id":"lr-101-' "$T/log/worker" | sed 's/^POST \/api\/jobs //' | jq -c '.meta // empty | fromjson' 2>/dev/null; }
djobs() { lwf_cnt '^POST /api/jobs .*"ticket_id":"lr-101-' "$T/log/worker"; }
fixround() {
  jq -nc '{fix_round_jobs:[{cap_key:"demo-os-BH-12", box:"box-b", claimed_by:"box-b"},
    {cap_key:"demo-os-BH-120", box:"box-c", claimed_by:"box-c"}], truncated:false}' > "$FX/fixrounds.json"
}

# ── DA1: build box and fix-round claimer ──
lwf_reset; lwf_needs example-org/demo-os 101; lwf_bv 101 APPROVE "$SHA" "" box-a; fixround
echo ticket/bh-12 > "$FX/ref.101"
lwf_tick
[ "$(djobs)" = 1 ] && ok || bad "DA1 jobs=$(djobs) (want 1): $(cat "$L")"
au=$(job_meta | jq -c '.head_authors // empty | fromjson' 2>/dev/null)
[ "$au" = '["box-a","box-b"]' ] && ok || bad "DA1 head_authors='$au' (want [\"box-a\",\"box-b\"]): $(grep '^POST /api/jobs' "$T/log/worker")"
grep -q 'GET /api/fix-rounds?project=demo-os&cap_key=demo-os-BH-12&limit=500' "$T/log/worker" && ok || bad "DA1 no keyed fix-round read: $(grep fix-rounds "$T/log/worker")"

# ── DA2: the fix-round reads fail ──
lwf_reset; lwf_needs example-org/demo-os 101; lwf_bv 101 APPROVE "$SHA" "" box-a; : > "$FX/fixrounds.fail"
echo ticket/bh-12 > "$FX/ref.101"
lwf_tick
[ "$(djobs)" = 1 ] && ok || bad "DA2 jobs=$(djobs) (want 1): $(cat "$L")"
au=$(job_meta | jq -c '.head_authors // empty | fromjson' 2>/dev/null)
[ "$au" = '["box-a"]' ] && ok || bad "DA2 head_authors='$au' (want [\"box-a\"])"
grep -q 'example-org/demo-os#101: fix-round lookup (project=demo-os&limit=500) failed' "$L" && ok || bad "DA2 no failure line: $(cat "$L")"

# ── DA3: no identity at all ──
lwf_reset; lwf_needs example-org/demo-os 101
lwf_tick
[ "$(djobs)" = 1 ] && ok || bad "DA3 jobs=$(djobs) (want 1): $(cat "$L")"
job_meta | jq -e 'has("head_authors")' >/dev/null 2>&1 && bad "DA3 a head_authors key with no identity: $(job_meta)" || ok
grep -q "example-org/demo-os#101 @${SHA:0:12}: no head authorship (no build or fix-round identity was readable); the job carries no head_authors" "$L" \
  && ok || bad "DA3 no reason line: $(cat "$L")"

echo "lead-review-enqueue-authors.bh-5351: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

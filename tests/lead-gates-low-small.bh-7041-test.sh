#!/bin/bash
# tests/lead-gates-low-small.bh-7041-test.sh — BH-7041: the low-small class in
# the worklist gate bin/lib/lead-gates.d/60-risk.sh (lg_gate_risk calls
# rt_low_small_apply right after rt_classify, as the enqueue does). Every case
# drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh plus
# tests/lib/lead-gates-fixture.bh-5875.sh), as tests/lead-gates-risk.bh-5875-test.sh
# does.
#   G1  no low_small row (shadow), a 180 code + 200 spec line head: reviewed
#       (a job), no post, risk.tsv medium, one WOULD line.
#   G2  the WOULD line text names the head, the own lines and the spec lines.
#   G3  enforce: one post with the low-small note, no job, risk.tsv col 5 low,
#       col 6 low-small:, col 8 low-small.
#   G4  shadow, a second tick on the same head: no second WOULD line.
#   G5  enforce, no builder APPROVE on the head: reviewed, no post.
#   G6  enforce, a head that drops an ok line from an existing test: medium,
#       reviewed, one `low-small no` line.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-low-small.bh-7041-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
HS=$(printf '%040d' 7041); S12=${HS:0:12}
HT=$(printf '%040d' 7042); T12=${HT:0:12}
RISK="$H/state/lead-review-enqueue/risk.tsv"
SMALLF='[["bin/foo.sh","modified",150,30,"@@ -1 +1 @@\n+x=1"],[".harness/specs/BH-1/plan.md","added",200,0,"@@ -0,0 +1 @@\n+plan"]]'
WEAKF='[["bin/foo.sh","modified",20,0,"@@ -1 +1 @@\n+x=1"],["tests/a-test.sh","modified",0,1,"@@ -1,2 +1,1 @@\n x=1\n-ok \"x\""]]'
summ() { lwf_summary; }
wouldn() { lwf_cnt 'risk-tier WOULD sign off (low-small:' "$L"; }
col() { awk -F'\t' -v h="$1" -v c="$2" '$4 == h {print $c}' "$RISK" 2>/dev/null | tail -1; }
# one <mode> <pr> <head> <files> [low_small_mode]: one worklist head, grace 0
one() {
  lgf_reset "$1"; lgf_needs "$2:$3"; lgf_cmp "$3" "$4"
  printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"
  rm -f "$FX/settings/risk_tier.low_small_mode"
  [ -n "${5:-}" ] && printf '%s' "$5" > "$FX/settings/risk_tier.low_small_mode"
  return 0
}

# ── G1: shadow (no row): reviewed, one WOULD line, medium ──
one enforce 141 "$HS" "$SMALLF"
lwf_tick
[ "$(lgf_jobs 141)" = 1 ] && ok || bad "G1 no job under shadow: $(cat "$L")"
[ "$(lgf_lv)" = 0 ] && ok || bad "G1 a lead-verdict call under shadow: $(cat "$T/log/lv")"
[ "$(col "$HS" 5)" = medium ] && ok || bad "G1 risk.tsv tier: $(cat "$RISK" 2>/dev/null)"
[ "$(wouldn)" = 1 ] && ok || bad "G1 want one WOULD line, got $(wouldn): $(grep -i low-small "$L")"

# ── G2: the WOULD line text ──
grep -qF "example-org/cromford#141 @$S12: risk-tier WOULD sign off (low-small: 180 code lines, 2 files (spec lines 200 not counted)); shadow" "$L" \
  && ok || bad "G2 the WOULD line: $(grep WOULD "$L")"

# ── G4: a second tick on the same head: no second WOULD line ──
lwf_tick
[ "$(wouldn)" = 1 ] && ok || bad "G4 a second WOULD line: $(grep WOULD "$L")"
# (other gates read the compare too; the tier is classified once: one risk-tiers POST)
[ "$(lgf_rt_posts)" = 1 ] && ok || bad "G4 risk-tiers POSTs after 2 ticks=$(lgf_rt_posts)"
[ "$(awk -F'\t' -v h="$HS" '$4 == h' "$RISK" | wc -l | tr -d ' ')" = 1 ] && ok || bad "G4 risk.tsv lines: $(cat "$RISK")"

# ── G3: enforce: signed off, risk.tsv low + low-small ──
one enforce 141 "$HS" "$SMALLF" enforce
lwf_tick
[ "$(lgf_signed 141)" = 1 ] && ok || bad "G3 sign-offs=$(lgf_signed 141): $(cat "$L")"
grep -q "^post example-org/cromford 141 $HS MERGE --source risk-tier --reviewer risk-tier:box-demo --note low risk: low-small: 180 code lines, 2 files (spec lines 200 not counted) --review-tier low --review-mode risk-tier$" "$T/log/lv" \
  && ok || bad "G3 lead-verdict argv: $(cat "$T/log/lv" 2>/dev/null)"
[ "$(lgf_jobs 141)" = 0 ] && ok || bad "G3 a lead_review job"
[[ "$(summ)" == *" skipped=1 "* ]] && ok || bad "G3 summary: $(summ)"
[ "$(col "$HS" 5)" = low ] && ok || bad "G3 risk.tsv col 5: $(cat "$RISK")"
case "$(col "$HS" 6)" in low-small:*) ok ;; *) bad "G3 risk.tsv col 6: $(cat "$RISK")" ;; esac
[ "$(col "$HS" 8)" = low-small ] && ok || bad "G3 risk.tsv col 8: $(cat "$RISK")"
grep -q 'WOULD sign off (low-small' "$L" && bad "G3 enforce logged a shadow WOULD line" || ok

# ── G5: enforce, no builder APPROVE on the head: reviewed, no post ──
one enforce 141 "$HS" "$SMALLF" enforce; rm -f "$FX/jv.approve"
lwf_tick
[ "$(lgf_lv)" = 0 ] && ok || bad "G5 an unapproved low-small head was signed off: $(cat "$T/log/lv")"
[ "$(lgf_jobs 141)" = 1 ] && ok || bad "G5 no job: $(cat "$L")"
grep -q "#141 @$S12: risk tier low, but no reviewer approved this head" "$L" && ok || bad "G5 no refusal line: $(grep '#141' "$L")"

# ── G6: enforce, a test that loses an ok line: medium, reviewed ──
one enforce 142 "$HT" "$WEAKF" enforce
lwf_tick
[ "$(lgf_lv)" = 0 ] && ok || bad "G6 a weakened test was signed off: $(cat "$T/log/lv")"
[ "$(lgf_jobs 142)" = 1 ] && ok || bad "G6 no job: $(cat "$L")"
[ "$(col "$HT" 5)" = medium ] && ok || bad "G6 risk.tsv: $(cat "$RISK")"
grep -qF "#142 @$T12: low-small no (tests/a-test.sh loses an assertion line); medium" "$L" && ok || bad "G6 no low-small no line: $(grep '#142' "$L")"

echo "lead-gates-low-small.bh-7041: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

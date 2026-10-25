#!/bin/bash
# tests/lead-gates-risk-ports.bh-7236-test.sh — the risk tier gate
# bin/lib/lead-gates.d/60-risk.sh, driven through bin/lead-review.sh tick WHOLE
# over tests/lib/lead-worklist-fixture.bh-4956.sh and tests/lib/lead-gates-fixture.bh-5875.sh.
#   B8   enforce, LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1, three low and two medium heads: three sign-offs, no job for a low head, one medium job.
#   B9   enforce, a low diff with a Lead-Lane: commit: no sign-off, no job, no risk-tiers POST, one [skip lead-lane] line.
#   B13  shadow: a second tick on the same rules posts no second risk-tiers row; a risk_tier.low_globs row makes the next tick classify the head again (medium).
#   B13b enforce: a head signed off as low is not signed off again after a low_globs row makes it medium; it gets a job.
#   B16  an unclassified head keeps one risk.tsv line, and the next tick does not read its compare in gate 60.
#   M1   60-risk.sh with the rules-signature check removed from its cache read: the B13 reclassification does not happen (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-risk-ports.bh-7236-test.sh
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
G60="$H/bin/lib/lead-gates.d/60-risk.sh"
[ -r "$G60" ] && ok || bad "setup: the closure did not install bin/lib/lead-gates.d/60-risk.sh"
HA=$(printf '%040d' 101); A12=${HA:0:12}
HB=$(printf '%040d' 102)
HC=$(printf '%040d' 103)
HM=$(printf '%040d' 104)
HN=$(printf '%040d' 105)
RISK="$H/state/lead-review-enqueue/risk.tsv"
MEDF='[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
LOWF='[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
tier_of() { awk -F'\t' -v h="$1" '$4 == h {t = $5} END {print t}' "$RISK" 2>/dev/null; }
last_rt_tier() { grep '^POST /api/risk-tiers ' "$T/log/worker" 2>/dev/null | tail -1 | sed 's/^POST \/api\/risk-tiers //' | jq -r '.tier' 2>/dev/null; }

# b13_shadow — the B13 shadow steps; prints "<posts after tick 1> <posts after tick 2> <posts after the rule change> <last tier> <tier after tick 1>"
b13_shadow() {
  local p1 p2 p3 t1
  lgf_reset shadow; lgf_needs "101:$HA"; lgf_cmp "$HA" "$LOWF"
  lwf_tick; p1=$(lgf_rt_posts); t1=$(tier_of "$HA")
  lwf_tick; p2=$(lgf_rt_posts)
  printf 'prompts/*' > "$FX/settings/risk_tier.low_globs"
  lwf_tick; p3=$(lgf_rt_posts)
  echo "$p1 $p2 $p3 $(last_rt_tier) $t1"
}

# ── B8: enforce signs off every low head, past the per-tick cap ──
lgf_reset enforce; lgf_needs "101:$HA" "102:$HB" "103:$HC" "104:$HM" "105:$HN"
for s in "$HA" "$HB" "$HC"; do lgf_cmp "$s" "$LOWF"; done
lgf_cmp "$HM" "$MEDF"; lgf_cmp "$HN" "$MEDF"; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 lwf_tick
[ "$(lgf_signed 101)$(lgf_signed 102)$(lgf_signed 103)" = 111 ] && ok || bad "B8 sign-offs under cap 1: $(cat "$T/log/lv" 2>/dev/null) :: $(cat "$L")"
[ "$(lgf_jobs 101)$(lgf_jobs 102)$(lgf_jobs 103)" = 000 ] && ok || bad "B8 a lead_review job for a signed head"
[ "$(lwf_cnt 'signed off by risk-tier' "$L")" = 3 ] && ok || bad "B8 signed lines=$(lwf_cnt 'signed off by risk-tier' "$L")"
[ $(( $(lgf_jobs 104) + $(lgf_jobs 105) )) = 1 ] && ok || bad "B8 the cap did not bite on the two medium heads: jobs $(lgf_jobs 104)+$(lgf_jobs 105)"

# ── B9: a Lead-Lane: commit with a low diff under enforce: never signed ──
lgf_reset enforce; lgf_needs "101:$HA"
lgf_cmp "$HA" "$LOWF" '[[1,"feat: x"],[1,"fix: y\n\nLead-Lane: mac"]]'
lwf_tick
[ "$(lgf_lv)" = 0 ] && ok || bad "B9 a lead-verdict call for a Lead-Lane head: $(cat "$T/log/lv" 2>/dev/null)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "B9 a lead_review job for a Lead-Lane head"
[ "$(lgf_rt_posts)" = 0 ] && ok || bad "B9 a risk-tiers POST for a Lead-Lane head"
[ "$(lwf_cnt "\[skip lead-lane\] example-org/cromford#101 @$A12 carries a Lead-Lane: commit; not reviewed" "$L")" = 1 ] \
  && ok || bad "B9 skip lines: $(cat "$L")"
[ -z "$(tier_of "$HA")" ] && ok || bad "B9 gate 60 wrote risk.tsv: $(cat "$RISK" 2>/dev/null)"

# ── B13: a rules change makes gate 60 classify a cached head again ──
read -r P1 P2 P3 T3 T1 <<<"$(b13_shadow)"
[ "$P1" = 1 ] && [ "$T1" = low ] && ok || bad "B13 first classification posts=$P1 tier=$T1"
[ "$P2" = 1 ] && ok || bad "B13 the same rules classified the head again: posts=$P2"
[ "$P3" = 2 ] && ok || bad "B13 a low_globs row did not classify the cached head again: posts=$P3"
[ "$T3" = medium ] && ok || bad "B13 the tightened rule did not apply: tier=$T3"
# B13b: enforce: the cached low head is not signed again under the tightened rules
lgf_reset enforce; lgf_needs "101:$HA"; lgf_cmp "$HA" "$LOWF"; echo 4 > "$FX/lvrc"
lwf_tick
[ "$(lgf_signed 101)" = 1 ] && ok || bad "B13b enforce setup: sign-offs=$(lgf_signed 101) :: $(cat "$L")"
rm -f "$FX/lvrc" "$H/state/lead-review-enqueue/risk-pub-"*
printf 'prompts/*' > "$FX/settings/risk_tier.low_globs"; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"
lwf_tick
[ "$(lgf_signed 101)" = 1 ] && ok || bad "B13b a cached low head was signed again under tightened rules: $(cat "$T/log/lv")"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "B13b no job for the now-medium head: $(cat "$L")"

# ── B16: an unclassified head stays cached; its compare is not read again ──
lgf_reset enforce; lgf_needs "101:$HA"
jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}]}' > "$FX/cmp.$HA"
LEAD_REVIEW_SILENCE_CHECK=0 lwf_tick
C1=$(lgf_cmp_reads "$HA")
[ "$(tier_of "$HA")" = unclassified ] && ok || bad "B16 risk.tsv after tick 1: $(cat "$RISK" 2>/dev/null)"
rm -f "$T/log/gh"
LEAD_REVIEW_SILENCE_CHECK=0 lwf_tick
C2=$(lgf_cmp_reads "$HA")
[ "$C1" = 2 ] && [ "$C2" = 1 ] && ok || bad "B16 compare reads: tick 1 $C1 (want 2: gates 15 and 60), tick 2 $C2 (want 1: gate 15 only)"
[ "$(awk -F'\t' -v h="$HA" '$4 == h && $5 == "unclassified"' "$RISK" | wc -l | tr -d ' ')" = 1 ] && ok || bad "B16 unclassified lines: $(cat "$RISK")"
[ "$(lgf_lv)" = 0 ] && ok || bad "B16 an unclassified head was signed off"

# ── M1: the cache ignores the rules signature: B13 goes red ──
cp "$G60" "$T/60.orig"
sed -i 's/ && \$7 == g {t = /  {t = /' "$G60"
if cmp -s "$G60" "$T/60.orig"; then bad "M1 the mutation did not change 60-risk.sh"
else
  read -r _ _ P3 _ _ <<<"$(b13_shadow)"
  [ "$P3" != 2 ] && ok || bad "M1 B13 stayed green with the rules-signature check removed: posts=$P3"
fi
cp "$T/60.orig" "$G60"
cmp -s "$G60" "$T/60.orig" && ok || bad "M1 60-risk.sh not restored"

echo "lead-gates-risk-ports.bh-7236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

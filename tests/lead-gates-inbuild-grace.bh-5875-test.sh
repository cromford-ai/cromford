#!/bin/bash
# tests/lead-gates-inbuild-grace.bh-5875-test.sh — BH-5875 (BH-5870.2): gate 5
# of the enqueue, the in-build grace (BH-5023), as the worklist gate
# bin/lib/lead-gates.d/70-inbuild-grace.sh, fed by 60-risk.sh's tier. Every
# case drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh plus
# tests/lib/lead-gates-fixture.bh-5875.sh). The head is medium (one bin/lib
# file, 50 lines) under risk_tier.mode enforce unless a case says otherwise.
#   I1  first sight: held=1, the enqueue's inbuild-wait marker written, no job.
#   I2  a marker older than the grace: a job and the `grace spent` line.
#   I3  job_verdict_headbound reapproved@<head>: a job, never held, no marker.
#   I4  job_verdict unreadable (500): held=1.
#   I5  risk_tier.inbuild_grace_s 0: a job.
#   I6  the head is in the enqueue's requested.tsv: a job.
#   I7  medium under shadow: the gate holds nothing.
#   I8  a builder APPROVE bound to this head: held (not a rebound).
# Every head has a running build job bound to it (BH-5740, gate 70's rule).
#   M1  70-inbuild-grace.sh removed: the I1 head gets a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-inbuild-grace.bh-5875-test.sh
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
GD="$H/bin/lib/lead-gates.d"
[ -r "$GD/70-inbuild-grace.sh" ] && ok || bad "setup: the closure did not install bin/lib/lead-gates.d/70-inbuild-grace.sh"
DIR="$LWF_SRC"
f="$DIR/bin/lib/lead-gates.d/70-inbuild-grace.sh"; [ -r "$f" ] && ok || bad "setup: $f missing"
HM=$(printf '%040d' 104); M12=${HM:0:12}
HO=$(printf '%040d' 999)
ST="$H/state/lead-review-enqueue"
WAITF="$ST/inbuild-wait-example-org_cromford-104-$M12"
MEDF='[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
LOWF='[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
summ() { lwf_summary; }
# TEST-CHANGE BH-5878: gate 70 now holds only while a build job runs the
# in-build review on the head (BH-5740, ported from the retired enqueue), so
# each head here has its build job running, bound to it.
bjob() { jq -nc --arg s "$HM" '{verdict:"APPROVE", reviewed_sha:$s, job_id:"job-fixture-build",
  job:{id:"job-fixture-build", kind:"build", status:"running"}}' > "$FX/jv.json"; }
med() { lgf_reset "${1:-enforce}"; lgf_needs "104:$HM"; lgf_cmp "$HM" "${2:-$MEDF}"; bjob; }

# ── I1: first sight: held, marker written ──
med
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "I1 a job on first sight: $(cat "$L")"
[[ "$(summ)" == *" held=1"* && "$(summ)" == *" started=0 "* ]] && ok || bad "I1 summary: $(summ)"
[ -e "$WAITF" ] && ok || bad "I1 no marker at $WAITF"
grep -q "#104 @$M12: awaiting the in-build lead-grade review (" "$L" && ok || bad "I1 line: $(cat "$L")"

# ── I2: the grace spent: reviewed ──
# TEST-CHANGE BH-5878: 2 hours old, not 2020: the gates now sweep these
# markers after 7 days (99-state-sweep.sh, the enqueue's retention).
med; mkdir -p "$ST"; : > "$WAITF"; touch -d '2 hours ago' "$WAITF"
printf 600 > "$FX/settings/risk_tier.inbuild_grace_s"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "I2 no job after the grace: $(cat "$L")"
grep -q "#104 @$M12: in-build grace spent (600 s, no in-build lead verdict); starting a lead review" "$L" && ok || bad "I2 line: $(cat "$L")"

# ── I3: a rebound head is never held ──
med
jq -nc --arg o "$HO" --arg h "reapproved@$HM" '{verdict:"APPROVE", reviewed_sha:$o, job_id:"job-fixture-1",
  artifacts:[{artifact_kind:"verdict", detail:({headbound:$h} | tojson)}]}' > "$FX/jv.json"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "I3 no job for a rebound head: $(cat "$L")"
[ -e "$WAITF" ] && bad "I3 a marker for a rebound head" || ok

# ── I4: the builder verdict unreadable: held ──
med; : > "$FX/jv.fail"
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "I4 a job on an unreadable builder verdict"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "I4 summary: $(summ)"
grep -q "#104 @$M12: builder verdict unreadable (rc 1); held" "$L" && ok || bad "I4 line: $(cat "$L")"

# ── I5: grace 0: reviewed ──
med; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "I5 no job with grace 0"

# ── I6: the enqueue already requested this head: reviewed ──
med; mkdir -p "$ST"
printf '%s\t%s\t%s\t%s\t%s\n' 1760000000 example-org/cromford 104 "$HM" r-104 > "$ST/requested.tsv"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "I6 no job for a requested head"
[ -e "$WAITF" ] && bad "I6 a marker for a requested head" || ok

# ── I7: shadow, or a low tier: nothing held ──
med shadow
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "I7 no job under shadow"
[ -e "$WAITF" ] && bad "I7 a marker under shadow" || ok

# ── I8: the builder APPROVE is on this head: held ──
med
bjob
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "I8 a job for a head-bound APPROVE"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "I8 summary: $(summ)"

# ── M1: no grace gate: the I1 head is reviewed ──
mv "$GD/70-inbuild-grace.sh" "$T/70.off"
med
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "M1 no job with 70-inbuild-grace.sh gone"
mv "$T/70.off" "$GD/70-inbuild-grace.sh"

echo "lead-gates-inbuild-grace.bh-5875: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

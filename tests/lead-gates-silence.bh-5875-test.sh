#!/bin/bash
# tests/lead-gates-silence.bh-5875-test.sh — BH-5875 (BH-5870.2): gate 9 of the
# enqueue, the silence check (BH-5797), as the worklist gate
# bin/lib/lead-gates.d/30-silence.sh, with its compare read from
# bin/lib/lead-gates-compare.sh. Every case drives bin/lead-review.sh tick
# WHOLE over the worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh
# plus tests/lib/lead-gates-fixture.bh-5875.sh) and the real
# catalog/silence-markers.tsv.
#   S1  a gitleaks marker: one label POST, one comment, `[skip silence]`, no job.
#   S2  a second tick: no second label or comment, still no job.
#   S2b the label removed by a person: the next tick starts the review.
#   S3  the comment POST fails: held=1, no skip line, no job, no state row.
#   S4  a lead-route marker (determinism, with its reason) on a low head under
#       enforce: a job (its meta carries silence_note), no sign-off, the note is
#       stored (BH-5878: no longer held for the enqueue). S4b: the same
#       marker with the risk tier off: a job too.
#   S5  bin/lib/silence-scan.sh absent: the review starts (no check).
#   S6  a scanned-* marker the enqueue wrote: gate 30 reads no compare.
#   S7  no default-branch read (the base is the PR's own) with gates 15, 30
#       and 60 on; at most 2 compare
#       reads; a second tick reads the compare again.
#   S8  LEAD_REVIEW_SILENCE_CHECK=0, or no rules file: no compare read by gate 30.
#   S9  the compare scratch cannot be written: held.
#   S10 a labelled row whose PR read fails: held.
#   M1  30-silence.sh removed: the S1 head gets a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-silence.bh-5875-test.sh
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
DIR="$LWF_SRC"
for f in "$DIR/bin/lib/lead-gates.d/30-silence.sh" "$DIR/bin/lib/lead-gates-compare.sh" "$DIR/bin/lib/silence-scan.sh"; do
  [ -r "$H/${f#"$DIR"/}" ] && ok || bad "setup: the closure did not install ${f#"$DIR"/}"
done
HA=$(printf '%040d' 101); A12=${HA:0:12}
SD="$H/state/lead-review-enqueue/silence"
# Markers are built from two halves, so this file adds none itself.
GLM="gitleaks:allo""w"
DTM="# determinism: o""k fixed clock for the fixture"
cmp_line() { # cmp_line <head> <added line>: one new test file adding that line
  lgf_cmp "$1" "$(jq -nc --arg l "$2" '[["tests/x.bh-1-test.sh","added",3,0,("@@ -0,0 +1,3 @@\n+#!/bin/bash\n+" + $l + "\n+exit 0")]]')"
}
summ() { lwf_summary; }
labels() { lwf_cnt '^api -i -X POST repos/example-org/cromford/issues/101/labels' "$T/log/gh"; }
comments() { lwf_cnt '^api -i -X POST repos/example-org/cromford/issues/101/comments' "$T/log/gh"; }
skips() { lwf_cnt '\[skip silence\] example-org/cromford#101' "$L"; }
leak_head() { lgf_reset "${1:-none}"; lgf_needs "101:$HA"; cmp_line "$HA" "TOKEN=tok-fixture-1 $GLM"; }

# ── S1: a public-leak marker: needs-human, no review ──
leak_head
lwf_tick
[ "$(labels)" = 1 ] && ok || bad "S1 label POSTs=$(labels): $(cat "$L")"
[ "$(comments)" = 1 ] && ok || bad "S1 comment POSTs=$(comments)"
[ "$(skips)" = 1 ] && ok || bad "S1 skip lines=$(skips)"
grep -q "\[skip silence\] example-org/cromford#101 @$A12: needs-human; not reviewed" "$L" && ok || bad "S1 skip line text: $(grep skip "$L")"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "S1 a lead_review job for 101"
[[ "$(summ)" == *" skipped=1 "* && "$(summ)" == *" held=0"* && "$(summ)" == *" started=0 "* ]] && ok || bad "S1 summary: $(summ)"
[ "$(cut -f2 "$SD/example-org_cromford-101" 2>/dev/null)" = labelled ] && ok || bad "S1 state row: $(cat "$SD/example-org_cromford-101" 2>/dev/null)"

# ── S2: the next tick: no second label or comment ──
lwf_tick
[ "$(labels)" = 1 ] && ok || bad "S2 label POSTs after 2 ticks=$(labels)"
[ "$(comments)" = 1 ] && ok || bad "S2 comment POSTs after 2 ticks=$(comments)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "S2 a lead_review job for 101"

# ── S2b: a person removed the label: the review starts ──
rm -f "$FX/labels.101"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "S2b no job after the label was removed: $(cat "$L")"
[ "$(cut -f2 "$SD/example-org_cromford-101" 2>/dev/null)" = cleared ] && ok || bad "S2b state row: $(cat "$SD/example-org_cromford-101" 2>/dev/null)"

# ── S3: the comment fails: held, no skip line, no state row ──
leak_head; : > "$FX/commentfail"
lwf_tick
[ "$(skips)" = 0 ] && ok || bad "S3 a skip line after a failed comment"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "S3 a lead_review job for 101"
[[ "$(summ)" == *" held=1"* && "$(summ)" == *" skipped=0 "* ]] && ok || bad "S3 summary: $(summ)"
[ -e "$SD/example-org_cromford-101" ] && bad "S3 a state row after a failed comment" || ok

# ── S4: a lead-route marker on a low head under enforce: reviewed, not signed ──
# TEST-CHANGE BH-5878: with the enqueue retired, a lead-route head is no longer
# held for the enqueue's request: the review starts and the markers ride in its
# scope notes (field silence_note). Gate 60 still signs no such head off.
lgf_reset enforce; lgf_needs "101:$HA"; cmp_line "$HA" "now=1 $DTM"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "S4 no lead_review job for 101: $(cat "$L")"
[ "$(lgf_lv)" = 0 ] && ok || bad "S4 a lead-verdict call: $(cat "$T/log/lv")"
grep -q "example-org/cromford#101 @$A12: silence markers for the lead to judge; they ride in the review notes" "$L" && ok || bad "S4 note line: $(cat "$L")"
grep -q 'a determinism lint marker' "$SD/note-example-org_cromford-101-$A12" 2>/dev/null && ok || bad "S4 the lead note: $(cat "$SD"/note-* 2>/dev/null)"
grep '^POST /api/jobs .*"ticket_id":"lr-101-' "$T/log/worker" | grep -q 'silence_note' && ok || bad "S4 the job meta carries no silence_note: $(grep '^POST /api/jobs ' "$T/log/worker")"
[ "$(labels)" = 0 ] && ok || bad "S4 a label POST for a lead-route marker"
# S4b: the same marker with the risk tier off: reviewed too
lgf_reset none; lgf_needs "101:$HA"; cmp_line "$HA" "now=1 $DTM"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "S4b no lead_review job for a lead-marker head with the risk tier off"

# ── S5: no silence lib: the review starts ──
mv "$H/bin/lib/silence-scan.sh" "$T/ss.off"
leak_head
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "S5 no job with silence-scan.sh absent: $(cat "$L")"
[ "$(labels)" = 0 ] && ok || bad "S5 a label POST with no lib"
mv "$T/ss.off" "$H/bin/lib/silence-scan.sh"

# ── S6: the enqueue's scanned-* marker: no compare read by gate 30 ──
leak_head
lwf_tick
C_NO=$(lgf_cmp_reads "$HA")
lgf_reset none; lgf_needs "101:$HA"; cmp_line "$HA" "echo clean"
mkdir -p "$SD"; : > "$SD/scanned-example-org_cromford-101-$A12"
lwf_tick
[ "$(lgf_cmp_reads "$HA")" = 1 ] && ok || bad "S6 compare reads=$(lgf_cmp_reads "$HA") (want 1: gate 15's only)"
[ "$C_NO" = 2 ] && ok || bad "S6 control: compare reads without the marker=$C_NO (want 2)"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "S6 no job: $(cat "$L")"

# ── S7: one repo read a tick, the compare shared by gates 30 and 60 ──
# TEST-CHANGE (main at #6037): gate 10 reads the default branch for its CI
# check when a head has no builder row, so S7 gives the head a builder APPROVE:
# the default-branch read it pins is the compare's (gates 15, 30, 60), not gate 10's.
lgf_reset enforce; lgf_needs "101:$HA"
jq -nc --arg s "$HA" '{verdict:"APPROVE", reviewed_sha:$s, job_id:"job-fixture-1"}' > "$FX/jv.json"
lgf_cmp "$HA" '[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
lwf_tick
# TEST-CHANGE (BH-5875 on #6023's new base): gate 15 and the shared compare now
# compare against the PR's own base (pulls/<n> .base.ref), not the repo's
# default branch, so the tick reads no repos/<slug>. The compare reads below
# are the sharing this case pins.
[ "$(grep -c '^api -i -X GET repos/example-org/cromford$' "$T/log/gh")" = 0 ] && ok || bad "S7 a default-branch read: $(grep -c 'GET repos/example-org/cromford$' "$T/log/gh")"
[ "$(lgf_cmp_reads "$HA")" = 2 ] && ok || bad "S7 compare reads=$(lgf_cmp_reads "$HA") (want 2: gate 15 and the shared one)"
grep -q "risk tier medium" "$L" && ok || bad "S7 the risk gate did not classify: $(cat "$L")"
lwf_tick
[ "$(lgf_cmp_reads "$HA")" = 3 ] && ok || bad "S7 tick 2 compare reads=$(lgf_cmp_reads "$HA") (want 3: gate 15 again, the scan and tier cached)"

# ── S8: the check off, or no rules file: gate 30 reads nothing ──
leak_head
LEAD_REVIEW_SILENCE_CHECK=0 lwf_tick
[ "$(lgf_cmp_reads "$HA")" = 1 ] && ok || bad "S8 knob 0: compare reads=$(lgf_cmp_reads "$HA")"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "S8 knob 0: no job"
leak_head; mv "$H/catalog/silence-markers.tsv" "$T/rules.off"
lwf_tick
[ "$(lgf_cmp_reads "$HA")" = 1 ] && ok || bad "S8 no rules: compare reads=$(lgf_cmp_reads "$HA")"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "S8 no rules: no job"
mv "$T/rules.off" "$H/catalog/silence-markers.tsv"

# ── S9: the compare scratch cannot be written: held ──
leak_head; mkdir -p "$H/state"; : > "$H/state/lead-review-gates"
lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "S9 a job with no compare scratch"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "S9 summary: $(summ)"
grep -q "#101 @$A12: silence check: compare unreadable" "$L" && ok || bad "S9 line: $(cat "$L")"
rm -f "$H/state/lead-review-gates"

# ── S10: a labelled row whose PR read fails: held ──
leak_head
lwf_tick
# TEST-CHANGE: since #6023 the fixture splits a PR read failure by TMPDIR
# (basefail in the tick, ghfail elsewhere), so both are set: every read of
# PR 101 fails. Gate 15 reads the same PR first, so the failed read may hold
# there; the head is held either way.
: > "$FX/basefail.101"; : > "$FX/ghfail.101"
lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "S10 a job on an unreadable PR"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "S10 summary: $(summ)"
grep -qE "#101.*unreadable.*held" "$L" && ok || bad "S10 line: $(cat "$L")"

# ── M1: no silence gate: the S1 head is reviewed ──
mv "$GD/30-silence.sh" "$T/30.off"
leak_head
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "M1 no job with 30-silence.sh gone"
[ "$(labels)" = 0 ] && ok || bad "M1 a label POST with the gate gone"
mv "$T/30.off" "$GD/30-silence.sh"

cat "$T/s10.log" >&2; echo "lead-gates-silence.bh-5875: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

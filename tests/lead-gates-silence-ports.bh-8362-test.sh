#!/bin/bash
# tests/lead-gates-silence-ports.bh-8362-test.sh — the silence check
# (bin/lib/silence-scan.sh, catalog/silence-markers.tsv) as the worklist's gate
# 30 holds it (bin/lib/lead-gates.d/30-silence.sh, bin/lib/lead-gates-compare.sh),
# for the two outcomes the gate suite (tests/lead-gates-silence.bh-5875-test.sh)
# does not pin. Every case drives bin/lead-review.sh tick WHOLE over the
# worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh plus
# tests/lib/lead-gates-fixture.bh-5875.sh).
#   SP1  a KNOWN_FAKE_IDENTIFIERS entry added in bin/share/mapping.py (a human
#        hit) and the label POST fails: no job, no PR comment, no state row.
#   SP2  a diff that adds a clean line, with no scanned-* marker, so gate 30
#        really reads and scans the compare: a job, no label POST, no comment.
#   M1   30-silence.sh removed: the SP1 head gets a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-silence-ports.bh-8362-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset LEAD_REVIEW_SILENCE_CHECK
lwf_setup
lgf_setup
GD="$H/bin/lib/lead-gates.d"
for f in bin/lib/lead-gates.d/30-silence.sh bin/lib/lead-gates-compare.sh bin/lib/silence-scan.sh; do
  [ -r "$LWF_SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
HA=$(printf '%040d' 102)
SD="$H/state/lead-review-enqueue/silence"
# The set name is built from two halves, so this file adds no marker itself.
KFI="KNOWN_FAKE_""IDENTIFIERS"
labels() { lwf_cnt '^api -i -X POST repos/example-org/cromford/issues/102/labels' "$T/log/gh"; }
comments() { lwf_cnt '^api -i -X POST repos/example-org/cromford/issues/102/comments' "$T/log/gh"; }
# hit_head — PR 102 adds a known-fakes entry inside the set (a human hit)
hit_head() {
  lgf_reset none; lgf_needs "102:$HA"
  lgf_cmp "$HA" "$(jq -nc --arg k "$KFI" '[["bin/share/mapping.py","modified",1,0,
    ("@@ -540,6 +540,7 @@ " + $k + " = {\n     \"acme-demo\",\n+    \"demo-client-x\",\n     \"zz-fixture\",")]]')"
}

# ── SP1: the label POST fails: held, no comment, no state row ──
hit_head; : > "$FX/labelfail"
lwf_tick
[ "$(labels)" = 1 ] && ok || bad "SP1 label POSTs=$(labels) (want the one failed try): $(cat "$L")"
[ "$(lgf_jobs 102)" = 0 ] && ok || bad "SP1 a job after a failed label: $(cat "$L")"
[ "$(comments)" = 0 ] && ok || bad "SP1 comment POSTs=$(comments) after a failed label"
[ -e "$SD/example-org_cromford-102" ] && bad "SP1 a state row after a failed label: $(cat "$SD/example-org_cromford-102")" || ok

# ── SP2: a clean diff that is really scanned: a job, no label, no comment ──
lgf_reset none; lgf_needs "102:$HA"
lgf_cmp "$HA" '[["bin/x.sh","modified",1,0,"@@ -1,2 +1,3 @@\n x\n+echo hi\n y"]]'
lwf_tick
[ "$(lgf_cmp_reads "$HA")" = 2 ] && ok || bad "SP2 compare reads=$(lgf_cmp_reads "$HA") (want 2: gate 15 and the scan)"
[ "$(lgf_jobs 102)" = 1 ] && ok || bad "SP2 no job on a clean diff: $(cat "$L")"
[ "$(labels)" = 0 ] && ok || bad "SP2 label POSTs=$(labels) on a clean diff"
[ "$(comments)" = 0 ] && ok || bad "SP2 comment POSTs=$(comments) on a clean diff"

# ── M1: no silence gate: the SP1 head is reviewed ──
mv "$GD/30-silence.sh" "$T/30.off"
hit_head; : > "$FX/labelfail"
lwf_tick
[ "$(lgf_jobs 102)" = 1 ] && ok || bad "M1 no job with 30-silence.sh gone: $(cat "$L")"
mv "$T/30.off" "$GD/30-silence.sh"

echo "lead-gates-silence-ports.bh-8362: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

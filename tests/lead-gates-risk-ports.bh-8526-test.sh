#!/bin/bash
# tests/lead-gates-risk-ports.bh-8526-test.sh — the risk gate
# (bin/lib/lead-gates.d/60-risk.sh) beside the silence gate
# (bin/lib/lead-gates.d/30-silence.sh) on the worklist. Every case drives
# bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh plus
# tests/lib/lead-gates-fixture.bh-5875.sh) and the real
# catalog/silence-markers.tsv, with the risk tier on enforce.
#   RP1 a new test file with a gitleaks marker: one label POST, the
#       `[skip silence]` line, no sign-off, no lead-verdict call, no job.
#   RP2 a new test file with a determinism marker and its reason: the risk
#       gate's "risk tier low, but the diff adds silence markers" line, no
#       lead-verdict call, one job.
#   RP3 a docs-only head: risk.tsv column 5 `low`, column 8 `path`, signed off.
#   M1  the risk gate's ss_note read skipped: the RP2 head is signed off (D1).
#   M2  the silence gate renamed to run after the risk gate: the RP1 head is
#       signed off (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-risk-ports.bh-8526-test.sh
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
SRC="$LWF_SRC"
for f in "$SRC/bin/lib/lead-gates.d/60-risk.sh" "$SRC/bin/lib/lead-gates.d/30-silence.sh" "$SRC/bin/lib/silence-scan.sh"; do
  [ -r "$H/${f#"$SRC"/}" ] && ok || bad "setup: the closure did not install ${f#"$SRC"/}"
done
RISKF="$H/state/lead-review-enqueue/risk.tsv"
# Markers are built from two halves, so this file adds none itself.
GLM="gitleaks:allo""w"
DTM="# determinism: o""k fixed clock for the fixture"
cmp_line() { # cmp_line <head> <added line>: one new test file adding that line
  lgf_cmp "$1" "$(jq -nc --arg l "$2" '[["tests/x.bh-1-test.sh","added",3,0,("@@ -0,0 +1,3 @@\n+#!/bin/bash\n+" + $l + "\n+exit 0")]]')"
}
labels() { lwf_cnt "^api -i -X POST repos/example-org/cromford/issues/$1/labels" "$T/log/gh"; }
H1=$(printf '%040d' 131); H2=$(printf '%040d' 132); H3=$(printf '%040d' 133)
leak_case() { lgf_reset enforce; lgf_needs "131:$H1"; cmp_line "$H1" "TOKEN=tok-fixture-1 $GLM"; lwf_tick; }
lead_case() { lgf_reset enforce; lgf_needs "132:$H2"; cmp_line "$H2" "now=1 $DTM"; lwf_tick; }

# ── RP1: a public-leak marker on a low head under enforce: needs-human, no sign-off ──
leak_case
[ "$(labels 131)" = 1 ] && ok || bad "RP1 label POSTs=$(labels 131): $(cat "$L")"
[ "$(lgf_lv)" = 0 ] && ok || bad "RP1 a lead-verdict call: $(cat "$T/log/lv" 2>/dev/null)"
[ "$(lgf_jobs 131)" = 0 ] && ok || bad "RP1 a lead_review job for 131"
grep -q "\[skip silence\] example-org/cromford#131 @${H1:0:12}: needs-human; not reviewed" "$L" && ok || bad "RP1 skip line: $(cat "$L")"
grep -q "#131 .*signed off by risk-tier" "$L" && bad "RP1 a risk-tier sign-off line: $(grep 'signed off' "$L")" || ok

# ── RP2: a lead-route marker on a low head under enforce: the lead reviews it ──
lead_case
grep -qF "example-org/cromford#132 @${H2:0:12}: risk tier low, but the diff adds silence markers for the lead to judge; no risk-tier sign-off, the lead review starts" "$L" \
  && ok || bad "RP2 the risk gate's refusal line: $(cat "$L")"
[ "$(lgf_lv)" = 0 ] && ok || bad "RP2 a lead-verdict call: $(cat "$T/log/lv" 2>/dev/null)"
[ "$(lgf_jobs 132)" = 1 ] && ok || bad "RP2 lead_review jobs for 132=$(lgf_jobs 132)"

# ── RP3: a docs-only head: low by path, signed off ──
lgf_reset enforce; lgf_needs "133:$H3"
lgf_cmp "$H3" '[["docs/a.md","modified",3,0,"@@ -1 +1,3 @@\n+a\n+b\n+c"]]'
lwf_tick
row=$(awk -F'\t' -v h="$H3" '$4 == h' "$RISKF" 2>/dev/null | tail -1)
[ "$(cut -f5 <<<"$row")" = low ] && ok || bad "RP3 risk.tsv column 5: $row"
[ "$(cut -f8 <<<"$row")" = path ] && ok || bad "RP3 risk.tsv column 8: $row"
[ "$(lgf_signed 133)" = 1 ] && ok || bad "RP3 sign-offs=$(lgf_signed 133): $(cat "$L")"

# ── M1: the risk gate skips its ss_note read: the RP2 head is signed off ──
mv "$GD/60-risk.sh" "$T/60-risk.keep"
sed 's/snote=""; command -v ss_note /snote=""; false /' "$T/60-risk.keep" > "$GD/60-risk.sh"
grep -q 'snote=""; false ' "$GD/60-risk.sh" && ok || bad "M1 the mutation did not apply"
lead_case
[ "$(lgf_lv)" = 1 ] && ok || bad "M1 lead-verdict calls=$(lgf_lv) with the note read skipped (want 1: RP2 does not pin the note read)"
mv "$T/60-risk.keep" "$GD/60-risk.sh"
cmp -s "$SRC/bin/lib/lead-gates.d/60-risk.sh" "$GD/60-risk.sh" && ok || bad "M1 restore"

# ── M2: the silence gate runs after the risk gate: the RP1 head is signed off ──
mv "$GD/30-silence.sh" "$GD/65-silence.sh"
leak_case
[ "$(lgf_lv)" = 1 ] && ok || bad "M2 lead-verdict calls=$(lgf_lv) with gate 30 after gate 60 (want 1: RP1 does not pin the order)"
mv "$GD/65-silence.sh" "$GD/30-silence.sh"
[ "$(cd "$GD" && ls)" = "$(cd "$SRC/bin/lib/lead-gates.d" && ls)" ] && ok || bad "M2 restore: the gate file list differs"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

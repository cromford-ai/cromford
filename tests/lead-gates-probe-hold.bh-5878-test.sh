#!/bin/bash
# tests/lead-gates-probe-hold.bh-5878-test.sh — BH-5878: gate 72
# (bin/lib/lead-gates.d/72-probe-hold.sh). The enqueue runs a PR's declared live
# probes before it asks for the lead review; a worklist start does not, so
# the worklist holds a head whose PR body
# declares a probe until the harness App's `<!-- live-probes:<head> -->`
# comment is on the PR, at most LEAD_REVIEW_PROBE_WAIT_MAX_MIN minutes. Every
# case drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh + the 5875, 5876 and 5878 layers).
#   P1  a probe declared, no App comment: held, no job.
#   P2  the App comment for this head: a review starts.
#   P3  the App comment names an EARLIER head: held.
#   P4  held past the bound (the hold marker 61 min old): a review starts and
#       the notes say `no live-probe comment after 60 min`.
#   P5  LEAD_REVIEW_PROBE_WAIT_MAX_MIN=0, or no probe declared: a review starts.
#   M1  a mutation: without gate 72, P1 starts a review.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-probe-hold.bh-5878-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5878.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
lg6_setup
lg8_setup
[ -r "$H/bin/lib/lead-gates.d/72-probe-hold.sh" ] && ok || bad "setup: the closure did not install bin/lib/lead-gates.d/72-probe-hold.sh"

HA=$(printf '%040d' 101); A12=${HA:0:12}
HE=$(printf 'e%.0s' {1..40})
BODY=$'## Why\nfixture\n\n## Live probes\n```live-probes\nprobe: hub-lease-check\n```\n'
WAITF="$H/state/lead-review-gates/probe-wait-example-org_cromford-101-$A12"
one() { # one [body] — PR 101 at HA, the builder's APPROVE on HA
  lg6_reset
  lgf_needs "101:$HA"; lg8_bv 101 APPROVE "$HA" 2026-10-15T10:00:00Z
  printf '%s' "${1-$BODY}" > "$FX/body.101"
}
# app <head> — the harness App's live-probe comment for <head> on PR 101
app() {
  jq -nc --arg h "$1" '[{body:("<!-- live-probes:" + $h + " -->\nprobe hub-lease-check: rc 0"), created_at:"2026-10-15T10:05:00Z",
    html_url:"https://github.com/example-org/cromford/pull/101#issuecomment-9", user:{login:"cromford[bot]", type:"Bot"}}]' > "$FX/thread.101.json"
}
jobs101() { lgf_jobs 101; }

# ── P1: declared, no comment: held ──
one
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "P1 jobs=$(jobs101) (want 0): $(cat "$L")"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "P1 summary: $(lwf_summary)"
grep -q "example-org/cromford#101 @$A12: live probes declared, no harness App comment for this head yet; held" "$L" && ok || bad "P1 hold line: $(cat "$L")"
[ -e "$WAITF" ] && ok || bad "P1 no hold marker"

# ── P2: the App comment for this head: start ──
one; app "$HA"
lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "P2 jobs=$(jobs101) (want 1): $(cat "$L")"

# ── P3: a comment for an earlier head: held ──
one; app "$HE"
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "P3 jobs=$(jobs101) (want 0)"

# ── P4: past the bound: start, with the note ──
one
mkdir -p "${WAITF%/*}"; : > "$WAITF"; touch -d '61 minutes ago' "$WAITF"
lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "P4 jobs=$(jobs101) (want 1): $(cat "$L")"
[[ "$(lg8_notes 101)" == *"; no live-probe comment after 60 min" ]] && ok || bad "P4 notes: $(lg8_notes 101)"

# ── P5: the knob off, or nothing declared: start ──
one
LEAD_REVIEW_PROBE_WAIT_MAX_MIN=0 lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "P5 knob 0: jobs=$(jobs101) (want 1)"
one $'## Why\nno probes here\n'
lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "P5 no probe: jobs=$(jobs101) (want 1)"
[ ! -e "$WAITF" ] && ok || bad "P5 a hold marker for a body with no probe"

# ── M1: a mutation: no gate 72 ──
mv "$H/bin/lib/lead-gates.d/72-probe-hold.sh" "$T/72.off"
one
lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "M1 without gate 72 the head is still held (the hold is not gate 72's)"
mv "$T/72.off" "$H/bin/lib/lead-gates.d/72-probe-hold.sh"

echo "lead-gates-probe-hold.bh-5878: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

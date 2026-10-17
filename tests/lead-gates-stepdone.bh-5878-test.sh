#!/bin/bash
# tests/lead-gates-stepdone.bh-5878-test.sh — BH-5878: gate 10
# (bin/lib/lead-gates.d/10-builder.sh) carries the enqueue's BH-6696 rules, so
# the worklist keeps them when bin/lead-review-enqueue.sh is gone. Every case
# drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh + the 5875, 5876 and 5878 layers).
#   S1  builder REQUEST_CHANGES on this head, a person's HUMAN-STEP-DONE after
#       the verdict: a review starts, the job meta carries stepdone_note, the
#       /start notes say `auto: HUMAN-STEP-DONE after the builder's
#       REQUEST_CHANGES`, and gate 50 reads no verdict history (no replay, no
#       delta: the enqueue's rule).
#   S2  builder BLOCK on this head, no answer: no job, `[skip builder-block]`.
#   S3  builder BLOCK on this head, answered: a review starts.
#   S4  the answer is older than the verdict: no job, `[skip no-approve]`.
#   S5  a lead-authored PR, answered: no job.
#   S6  the thread is unreadable: no job, the skip text ends
#       `; human-step check: the thread of #<issue> is unreadable`.
#   S7  REQUEST_CHANGES on an EARLIER head, CI green on this head: a review
#       starts (unapproved, `auto: CI green`); with
#       LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1, no job and `[skip no-approve]`.
#   M1  a mutation: gate 10 without the step-done branch makes S1 start nothing.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-stepdone.bh-5878-test.sh
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
[ -r "$H/bin/lib/lead-step-done.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-step-done.sh"

HA=$(printf 'a%.0s' {1..40}); A12=${HA:0:12}
HE=$(printf 'e%.0s' {1..40})
VAT=2026-10-15T10:00:00Z
# thread <issue> <answer at> [answer login] — NEEDS-HUMAN by the builder, then the answer
thread() {
  jq -nc --arg at "$2" --arg who "${3:-a-person}" '[
    {body:"NEEDS-HUMAN: set the fixture env row", created_at:"2026-10-15T09:00:00Z",
     html_url:"https://github.com/example-org/cromford/issues/77#issuecomment-1", user:{login:"cromford[bot]", type:"Bot"}},
    {body:"HUMAN-STEP-DONE: the row is set", created_at:$at,
     html_url:"https://github.com/example-org/cromford/issues/77#issuecomment-2", user:{login:$who, type:"User"}}]' > "$FX/thread.$1.json"
}
# one <verdict> <reviewed sha> — PR 101 at HA, body `Closes #77`, CI green on HA
one() {
  lg6_reset
  lgf_needs "101:$HA"
  printf 'Closes #77\n\n## Why\nfixture\n' > "$FX/body.101"
  lg8_bv 101 "$1" "$2" "$VAT"
}
jobs101() { lgf_jobs 101; }
# gate 50's whole-history reads: before the /start (gate 20 reads with
# standing_only=1; review_one's own lw_replay reads after the /start)
hist101() { awk '/^POST \/api\/lead-reviews\/start /{exit} /^GET \/api\/verdicts\?repo=example-org\/cromford&pr=101 /{c++} END {print c+0}' "$T/log/worker" 2>/dev/null; }

# ── S1: REQUEST_CHANGES on this head, answered after the verdict ──
one REQUEST_CHANGES "$HA"; thread 77 2026-10-15T11:00:00Z
lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "S1 jobs=$(jobs101) (want 1): $(cat "$L")"
[[ "$(lg6_meta 101 stepdone_note)" == "human step answered after the builder's REQUEST_CHANGES: https://github.com/example-org/cromford/issues/77#issuecomment-2 by @a-person at 2026-10-15T11:00:00Z: HUMAN-STEP-DONE: the row is set" ]] \
  && ok || bad "S1 stepdone_note=$(lg6_meta 101 stepdone_note)"
[[ "$(lg8_notes 101)" == "auto: HUMAN-STEP-DONE after the builder's REQUEST_CHANGES on $A12; human step answered after the builder's REQUEST_CHANGES: "* ]] \
  && ok || bad "S1 /start notes: $(lg8_notes 101)"
[ "$(hist101)" = 0 ] && ok || bad "S1 gate 50 read the verdict history (a replay or delta path): $(grep verdicts "$T/log/worker")"
grep -q "example-org/cromford#101 @$A12: the builder's REQUEST_CHANGES is answered by https://github.com/example-org/cromford/issues/77#issuecomment-2 (@a-person at 2026-10-15T11:00:00Z)" "$L" \
  && ok || bad "S1 no answered line: $(cat "$L")"

# ── S2: BLOCK on this head, no answer ──
one BLOCK "$HA"
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "S2 jobs=$(jobs101) (want 0)"
grep -qF "[skip builder-block] example-org/cromford#101 @$A12 builder BLOCK; the fix round owns it" "$L" && ok || bad "S2 skip line: $(grep skip "$L")"

# ── S3: BLOCK on this head, answered ──
one BLOCK "$HA"; thread 77 2026-10-15T11:00:00Z
lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "S3 jobs=$(jobs101) (want 1): $(cat "$L")"
[[ "$(lg8_notes 101)" == "auto: HUMAN-STEP-DONE after the builder's BLOCK on $A12; "* ]] && ok || bad "S3 notes: $(lg8_notes 101)"

# ── S4: the answer is older than the verdict ──
one REQUEST_CHANGES "$HA"; thread 77 2026-10-15T09:30:00Z
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "S4 jobs=$(jobs101) (want 0)"
grep -qF "[skip no-approve] example-org/cromford#101 @$A12 builder verdict 'REQUEST_CHANGES' is not APPROVE" "$L" && ok || bad "S4 skip line: $(grep skip "$L")"

# ── S5: a lead-authored PR, answered ──
one REQUEST_CHANGES "$HA"; thread 77 2026-10-15T11:00:00Z; echo lead-bot > "$FX/author.101"
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "S5 jobs=$(jobs101) (want 0): $(cat "$L")"
[ "$(lwf_cnt '\[skip no-approve\] example-org/cromford#101 ' "$L")" = 1 ] && ok || bad "S5 skip line: $(grep skip "$L")"

# ── S6: the thread cannot be read ──
one REQUEST_CHANGES "$HA"; : > "$FX/thread.77.fail"
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "S6 jobs=$(jobs101) (want 0)"
grep -qF "builder verdict 'REQUEST_CHANGES' is not APPROVE; human-step check: the thread of #77 is unreadable" "$L" && ok || bad "S6 skip text: $(grep skip "$L")"

# ── S7: REQUEST_CHANGES on an earlier head: unapproved, then CI green ──
one REQUEST_CHANGES "$HE"
lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "S7 jobs=$(jobs101) (want 1): $(cat "$L")"
[[ "$(lg8_notes 101)" == "auto: CI green on $A12"* ]] && ok || bad "S7 notes: $(lg8_notes 101)"
grep -q "example-org/cromford#101 @$A12: the builder's REQUEST_CHANGES is on ${HE:0:12}, an earlier head; it does not stand on this head" "$L" \
  && ok || bad "S7 no earlier-head line: $(cat "$L")"
one REQUEST_CHANGES "$HE"
LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "S7 REQB=1 jobs=$(jobs101) (want 0)"
grep -qF "[skip no-approve] example-org/cromford#101 @$A12 the builder's REQUEST_CHANGES is on ${HE:0:12}, not this head, and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1" "$L" \
  && ok || bad "S7 REQB=1 skip line: $(grep skip "$L")"

# ── M1: a mutation: no step-done branch, S1 starts nothing ──
G10="$H/bin/lib/lead-gates.d/10-builder.sh"
# The mutant keeps the original beside it (sed -i.orig) and is restored with mv.
sed -i.orig 's/lsd_check "\$slug"/false "$slug"/' "$G10"
if cmp -s "$G10" "$G10.orig"; then bad "M1 the mutation did not apply (no lsd_check call in gate 10)"
else
  one REQUEST_CHANGES "$HA"; thread 77 2026-10-15T11:00:00Z
  lwf_tick
  [ "$(jobs101)" = 0 ] && ok || bad "M1 the mutant still started a review"
fi
mv "$G10.orig" "$G10"

echo "lead-gates-stepdone.bh-5878: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

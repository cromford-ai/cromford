#!/bin/bash
# tests/lead-gates-builder-earlier-head.bh-7236-test.sh — gate 10
# (bin/lib/lead-gates.d/10-builder.sh) on a builder refusal bound to an earlier
# head. Every case drives bin/lead-review.sh tick WHOLE over the worklist
# fixture (tests/lib/lead-worklist-fixture.bh-4956.sh + the 5875, 5876 and 5878 layers).
#   E2b REQUEST_CHANGES on an EARLIER head, CI not green on this head, a
#       person's HUMAN-STEP-DONE in the thread: no job, no `is answered by` line.
#   E10 REQUEST_CHANGES on an EARLIER head, CI not green: no job, no skip line,
#       one `does not stand on this head` line, one `CI not known green ...; held` line.
#   E11 BLOCK on an EARLIER head, CI not green: no job, no `[skip builder-block]`,
#       one `does not stand on this head` line, one `CI not known green ...; held` line.
#   E13 REQUEST_CHANGES on THIS head, no human step: no job, one
#       `[skip no-approve] ... builder verdict 'REQUEST_CHANGES' is not APPROVE` line.
#   M1  a mutation: gate 10 that lets an earlier-head refusal stand makes E10 red.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-builder-earlier-head.bh-7236-test.sh
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

HA=$(printf 'a%.0s' {1..40}); A12=${HA:0:12}
HE=$(printf 'e%.0s' {1..40}); E12=${HE:0:12}
VAT=2026-10-15T10:00:00Z
P="example-org/cromford#101"
# thread <issue> — NEEDS-HUMAN by the builder, then a person's answer after the verdict
thread() {
  jq -nc '[
    {body:"NEEDS-HUMAN: set the fixture env row", created_at:"2026-10-15T09:00:00Z",
     html_url:"https://github.com/example-org/cromford/issues/77#issuecomment-1", user:{login:"cromford[bot]", type:"Bot"}},
    {body:"HUMAN-STEP-DONE: the row is set", created_at:"2026-10-15T11:00:00Z",
     html_url:"https://github.com/example-org/cromford/issues/77#issuecomment-2", user:{login:"a-person", type:"User"}}]' > "$FX/thread.$1.json"
}
# one <verdict> <reviewed sha> — PR 101 at HA, body `Closes #77`, no CI run on HA
one() {
  lg6_reset
  lgf_needs "101:$HA"
  rm -f "$FX/checks.$HA"
  printf 'Closes #77\n\n## Why\nfixture\n' > "$FX/body.101"
  lg8_bv 101 "$1" "$2" "$VAT"
}
jobs101() { lgf_jobs 101; }
skips101() { lwf_cnt "\\[skip [a-z-]*\\] $P " "$L"; }
earlier() { lwf_cnt "$P @$A12: the builder's $1 is on $E12, an earlier head; it does not stand on this head" "$L"; }
held101() { lwf_cnt "$P @$A12: no builder APPROVE on this head and CI not known green .*; held" "$L"; }

# ── E2b: REQUEST_CHANGES on an earlier head, an answer in the thread ──
one REQUEST_CHANGES "$HE"; thread 77
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "E2b jobs=$(jobs101) (want 0): $(cat "$L")"
[ "$(lwf_cnt "$P @$A12: the builder's REQUEST_CHANGES is answered by" "$L")" = 0 ] && ok || bad "E2b an earlier head's refusal took the step-done path: $(cat "$L")"

# ── E10: REQUEST_CHANGES on an earlier head, CI not green ──
e10() {
  one REQUEST_CHANGES "$HE"
  lwf_tick
  [ "$(jobs101)" = 0 ] || return 1
  [ "$(skips101)" = 0 ] || return 2
  [ "$(earlier REQUEST_CHANGES)" = 1 ] || return 3
  [ "$(held101)" = 1 ] || return 4
  return 0
}
e10; rc=$?
[ "$rc" = 0 ] && ok || bad "E10 check $rc failed (1 jobs, 2 skip, 3 earlier-head line, 4 held line): $(cat "$L")"

# ── E11: BLOCK on an earlier head, CI not green ──
one BLOCK "$HE"
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "E11 jobs=$(jobs101) (want 0)"
[ "$(lg6_skips builder-block)" = 0 ] && ok || bad "E11 an earlier-head BLOCK still stands: $(grep skip "$L")"
[ "$(earlier BLOCK)" = 1 ] && ok || bad "E11 no earlier-head line: $(cat "$L")"
[ "$(held101)" = 1 ] && ok || bad "E11 the head did not reach the CI gate: $(cat "$L")"

# ── E13: REQUEST_CHANGES on this head, no human step ──
one REQUEST_CHANGES "$HA"
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "E13 jobs=$(jobs101) (want 0)"
[ "$(lwf_cnt "\\[skip no-approve\\] $P @$A12 builder verdict 'REQUEST_CHANGES' is not APPROVE" "$L")" = 1 ] \
  && ok || bad "E13 a current-head REQUEST_CHANGES must still stand: $(grep skip "$L")"

# ── M1: a mutation: an earlier-head refusal stands, E10 goes red ──
G10="$H/bin/lib/lead-gates.d/10-builder.sh"
# The mutant keeps the original beside it (sed -i.orig) and is restored with mv.
sed -i.orig 's/ && \[ "\$rsha" != "\$head" \]; then/ \&\& false; then/' "$G10"
if cmp -s "$G10" "$G10.orig"; then bad "M1 the mutation did not apply (no earlier-head test in gate 10)"
else
  e10 && bad "M1 E10 still passed under the mutant" || ok
fi
mv "$G10.orig" "$G10"

echo "lead-gates-builder-earlier-head.bh-7236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

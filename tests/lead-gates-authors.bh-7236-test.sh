#!/bin/bash
# tests/lead-gates-authors.bh-7236-test.sh — the head-authors job field of the
# worklist (bin/lib/lead-gates.d/25-authors.sh, _lga_head_authors_json): the
# rules tests/lead-review-enqueue-authors.bh-5351-test.sh DA1-DA3 do not pin.
# bin/lead-review.sh tick runs WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh;
# the head ref comes from the PR body gate 55 read; both fix-round reads answer
# $FX/fixrounds.json.
#   A1 the build box, then the box and claimed_by of the fix rounds whose
#      cap_key names BH-12 (never BH-120), starts dqw-101-, or whose args[3] is
#      the PR url; trimmed, lowercased, de-duplicated. Both fix-round reads use
#      the existing filters only (no pr filter); no failure line on a good read.
#   A2 no build job recorded the PR (verdict read 404), CI green, no fix rounds: the
#      log names the 404, and the job carries no head_authors.
#   A3 a truncated fix-round list: what was read is sent, the log says so.
#   A4 a participant build: job.box participant:mac-a, then job.participant.
#   A5 over 16 identities: the first 16 are sent, the build identity first.
#   M1 a lib copy that does not lowercase: A1 goes red (D1).
#   M2 a lib copy with no cap of 16: A5 goes red (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-authors.bh-7236-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
GATE="$H/bin/lib/lead-gates.d/25-authors.sh"
[ -r "$GATE" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/25-authors.sh"
URL101="https://github.com/example-org/demo-os/pull/101"
job_meta() { grep '^POST /api/jobs .*"ticket_id":"lr-101-' "$T/log/worker" | sed 's/^POST \/api\/jobs //' | jq -c '.meta // empty | fromjson' 2>/dev/null; }
djobs() { lwf_cnt '^POST /api/jobs .*"ticket_id":"lr-101-' "$T/log/worker"; }
authors() { job_meta | jq -c '.head_authors // "ABSENT" | if . == "ABSENT" then . else fromjson end' 2>/dev/null; }
# one [box] — PR 101 at SHA on ticket/bh-12, its builder APPROVE from <box>
one() { lwf_reset; lwf_needs example-org/demo-os 101; lwf_bv 101 APPROVE "$SHA" "" "${1:-box-a}"; echo ticket/bh-12 > "$FX/ref.101"; }
rounds() {
  jq -nc --arg u "$URL101" '{fix_round_jobs:[
      {id:1, cap_key:"demo-os-BH-12", box:" ORGO-3 ", claimed_by:"orgo-3b"},
      {id:2, cap_key:"dqw-101-aaaaaaaaaaaa-ci", box:"orgo-4", claimed_by:null},
      {id:3, cap_key:"demo-os-BH-120", box:"orgo-9", claimed_by:"orgo-9b"},
      {id:4, cap_key:"dqw-1010-bbbbbbbbbbbb-ci", box:"orgo-8", claimed_by:null},
      {id:5, cap_key:"resolver-x", box:"orgo-5", claimed_by:null, args:["demo-os","BH-7","blocked",$u,"rec","BH-7"]},
      {id:6, cap_key:"resolver-y", box:"orgo-7", claimed_by:null, args:["demo-os","BH-8","blocked",($u + "0"),"rec","BH-8"]}
    ], truncated:false}' > "$FX/fixrounds.json"
}
a1() { [ "$(djobs)" = 1 ] && [ "$(authors)" = '["orgo-2","orgo-3","orgo-3b","orgo-4","orgo-5"]' ]; }
twenty() {
  jq -nc '{fix_round_jobs:[range(1; 21) | {id:., cap_key:("demo-os-BH-12-" + (.|tostring)), box:("fx-" + (.|tostring)), claimed_by:null}], truncated:false}' > "$FX/fixrounds.json"
}
a5() { [ "$(jq -c 'length, .[0]' <<<"$(authors)" | tr '\n' ' ')" = '16 "orgo-2" ' ]; }

# ── A1: the build box and the fix-round identities ──
one orgo-2; rounds; lwf_tick
a1 && ok || bad "A1 jobs=$(djobs) head_authors=$(authors): $(cat "$L")"
grep -qF 'GET /api/fix-rounds?project=demo-os&cap_key=demo-os-BH-12&limit=500' "$T/log/worker" && ok \
  || bad "A1 no cap_key read: $(grep fix-rounds "$T/log/worker")"
grep -qF 'GET /api/fix-rounds?project=demo-os&limit=500' "$T/log/worker" && ok \
  || bad "A1 no project read: $(grep fix-rounds "$T/log/worker")"
grep -q 'fix-rounds?\(.*&\)\?pr[_=]' "$T/log/worker" && bad "A1 a pr filter reached the fix-rounds route" || ok
grep -q 'head_authors may be incomplete\|no head authorship' "$L" && bad "A1 logged a failure on a good read: $(cat "$L")" || ok

# ── A2: the verdict read answers 404, no fix rounds ──
one; rm -f "$FX/bv.101"; : > "$FX/bv.101.none"; lwf_ci_green "$SHA"; lwf_tick
[ "$(djobs)" = 1 ] && ok || bad "A2 jobs=$(djobs) on a CI-green head with no build job: $(cat "$L")"
grep -qF 'example-org/demo-os#101: no build job recorded the PR; head_authors has no build identity' "$L" && ok || bad "A2 no 404 line: $(cat "$L")"
job_meta | jq -e 'has("head_authors")' >/dev/null 2>&1 && bad "A2 a head_authors key with no identity: $(job_meta)" || ok
rm -f "$FX/bv.101.none"

# ── A3: a truncated fix-round list ──
one orgo-2; rounds; jq -c '.truncated = true | .fix_round_jobs |= .[:2]' "$FX/fixrounds.json" > "$T/fr.tmp" && mv "$T/fr.tmp" "$FX/fixrounds.json"
lwf_tick
[ "$(authors)" = '["orgo-2","orgo-3","orgo-3b","orgo-4"]' ] && ok || bad "A3 head_authors=$(authors)"
grep -qF 'example-org/demo-os#101: fix-round list truncated; head_authors may be incomplete' "$L" && ok || bad "A3 log: $(cat "$L")"

# ── A4: a participant build ──
one; jq -nc --arg s "$SHA" '{verdict:"APPROVE", reviewed_sha:$s, artifacts:[], job:{box:"participant:Mac-A", participant:"mac-a"}}' > "$FX/bv.101"
lwf_tick
[ "$(jq -c '.[:2]' <<<"$(authors)")" = '["participant:mac-a","mac-a"]' ] && ok || bad "A4 head_authors=$(authors)"

# ── A5: over 16 ──
one orgo-2; twenty; lwf_tick
a5 && ok || bad "A5 head_authors=$(authors)"
grep -qF 'example-org/demo-os#101: head_authors over 16; first 16 sent' "$L" && ok || bad "A5 log: $(cat "$L")"

# ── M1, M2: break the gate's rules in the scratch copy; A1 and A5 go red ──
cp "$GATE" "$T/25.orig"
sed -i 's/| ascii_downcase | select(. != "")/| select(. != "")/' "$GATE"
if cmp -s "$GATE" "$T/25.orig"; then bad "M1 the mutation did not change the gate"
else one orgo-2; rounds; lwf_tick; a1 && bad "M1 A1 stayed green without the lowercase" || ok; fi
cp "$T/25.orig" "$GATE"
sed -i 's/all=$(jq -c '"'"'\.\[:16\]'"'"' <<<"$all")/:/' "$GATE"
if cmp -s "$GATE" "$T/25.orig"; then bad "M2 the mutation did not change the gate"
else one orgo-2; twenty; lwf_tick; a5 && bad "M2 A5 stayed green without the cap" || ok; fi
cp "$T/25.orig" "$GATE"

echo "lead-gates-authors.bh-7236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

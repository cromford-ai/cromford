#!/bin/bash
# tests/lead-gates-tier-notes.bh-5878-test.sh — BH-5878: gates 50
# (50-replay-delta.sh) and 60 (60-risk.sh) carry the enqueue's BH-6967 tier and
# mode tokens, its BH-5909 console-QA replay hold and its replay review mode, so
# the worklist keeps them when bin/lead-review-enqueue.sh is gone. Every case
# drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh + the 5875, 5876 and 5878 layers).
#   T1  low + enforce, builder APPROVE on the head: the sign-off argv ends
#       `--review-tier low --review-mode risk-tier`.
#   T2  medium + risk_tier.medium_mode intent, no delta: the /start notes end
#       `; review-tier:medium review-mode:intent`, stored in
#       state/lead-review-enqueue/review-tier-<slug_>-<n>-<sha12>.
#   T3  medium + intent, a delta class from gate 50: the notes carry the
#       `lead-delta:` group and end `review-tier:medium review-mode:full`.
#   T4  a stored review-tier file: its tokens are sent, not the new ones.
#   T5  the medium_mode row unreadable: full, and one log line says why.
#   T6  self-check notes of 3990 chars: the notes stay within 4000 and the
#       tokens stay whole as the last group.
#   T7  a replay class on a console-ui/src/ head with no QA: PASS and the
#       console QA gate row on: no replay post, a full review starts.
#   T8  the replay post fails: held, no job.
#   T9  the replayed lead row was an intent review: the post carries
#       `--review-mode intent`; a row with no mode posts `--review-mode full`.
#   T10 a review-tier marker older than 7 days is deleted on the tick; a
#       fresh one stays (lg_tick_risk's prune: the enqueue that pruned them
#       runs on the hub only).
#   M1  a mutation: gate 60 without the token field makes T2's notes end
#       with no tokens.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-tier-notes.bh-5878-test.sh
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

HA=$(printf '%040d' 101); A12=${HA:0:12}
G=$(printf 'd%.0s' {1..40}); G12=${G:0:12}
ST="$H/state/lead-review-enqueue"
LOWF='[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
MEDF='[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
# The delta knob the gate keys its delta.tsv rows on, read the gate's way.
LDMAX=$(cd "$T" && HARNESS="$H" bash -c '. "$HARNESS/bin/lib/lead-delta.sh"; ld_knob LEAD_DELTA_REVIEW_MAX_LINES') || LDMAX=""
[ -n "$LDMAX" ] && ok || bad "setup: LEAD_DELTA_REVIEW_MAX_LINES unresolved in the scratch harness"
# one <mode> <head> <files> — PR 101, the builder's APPROVE on <head>
one() {
  lg6_reset "$1"
  lgf_needs "101:$2"; lgf_cmp "$2" "$3"
  lg8_bv 101 APPROVE "$2" 2026-10-15T10:00:00Z
}
# prior <word> [review_mode] — a lead row on G, an earlier head of PR 101
prior() {
  jq -nc --arg g "$G" --arg w "$1" --arg m "${2:-}" '{rows:[{id:7, source:"lead", head_sha:$g, verdict:$w, note:"",
    created_at:"2026-10-15T09:00:00Z"} + (if $m == "" then {} else {review_mode:$m} end)], truncated:false}' > "$FX/verdicts.json"
}
# cls <head> <class> — the class gate 50 cached for (G, head)
cls() { mkdir -p "$ST"; printf '%s\texample-org/cromford\t101\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$G" "$1" "$LDMAX" "$2" >> "$ST/delta.tsv"; }
replay_posts() { lwf_cnt "^post example-org/cromford 101 .* --note lead-replay:$G12 " "$T/log/lv"; }

# ── T1: low + enforce: the sign-off carries the tier and mode ──
one enforce "$HA" "$LOWF"
lwf_tick
grep -q "^post example-org/cromford 101 $HA MERGE --source risk-tier --reviewer risk-tier:box-demo --note low risk: .* --review-tier low --review-mode risk-tier$" "$T/log/lv" \
  && ok || bad "T1 lead-verdict argv: $(cat "$T/log/lv" 2>/dev/null) / $(cat "$L")"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "T1 a job after a sign-off"

# ── T2: medium + intent: the tokens end the notes and are stored ──
one shadow "$HA" "$MEDF"; printf intent > "$FX/settings/risk_tier.medium_mode"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "T2 jobs=$(lgf_jobs 101): $(cat "$L")"
[[ "$(lg8_notes 101)" == "auto: builder APPROVE on $A12; review-tier:medium review-mode:intent" ]] && ok || bad "T2 notes: $(lg8_notes 101)"
[ "$(cat "$ST/review-tier-example-org_cromford-101-$A12" 2>/dev/null)" = "review-tier:medium review-mode:intent" ] && ok \
  || bad "T2 stored tokens: $(cat "$ST/review-tier-example-org_cromford-101-$A12" 2>/dev/null)"

# ── T3: medium + intent + a delta: full, with the delta group ──
one shadow "$HA" "$MEDF"; printf intent > "$FX/settings/risk_tier.medium_mode"
prior MERGE; cls "$HA" "delta 5 $LDMAX 1"
lwf_tick
[[ "$(lg8_notes 101)" == "auto: builder APPROVE on $A12; lead-delta:$G lines:5/$LDMAX files:1; lead-prev:$G word:MERGE "*"; review-tier:medium review-mode:full" ]] \
  && ok || bad "T3 notes: $(lg8_notes 101)"

# ── T4: a stored file wins ──
one shadow "$HA" "$MEDF"
mkdir -p "$ST"; printf 'review-tier:high review-mode:full' > "$ST/review-tier-example-org_cromford-101-$A12"
lwf_tick
[[ "$(lg8_notes 101)" == *"; review-tier:high review-mode:full" ]] && ok || bad "T4 notes: $(lg8_notes 101)"

# ── T5: the medium_mode row unreadable: full, said once ──
one shadow "$HA" "$MEDF"; printf FAIL > "$FX/settings/risk_tier.medium_mode"
lwf_tick
[[ "$(lg8_notes 101)" == *"; review-tier:medium review-mode:full" ]] && ok || bad "T5 notes: $(lg8_notes 101)"
[ "$(lwf_cnt 'risk_tier.medium_mode unreadable' "$L")" = 1 ] && ok || bad "T5 log lines: $(grep medium_mode "$L")"

# ── T6: long notes: the tokens stay whole and last ──
one shadow "$HA" "$MEDF"
mkdir -p "$ST"; printf 'self-check notes: %s' "$(head -c 3972 /dev/zero | tr '\0' 'n')" > "$ST/selfcheck-notes-example-org_cromford-101-$A12"
lwf_tick
N6=$(lg8_notes 101)
[ "${#N6}" -le 4000 ] && [ "${#N6}" -gt 3900 ] && ok || bad "T6 notes length ${#N6}"
[[ "$N6" == *"; review-tier:medium review-mode:full" ]] && ok || bad "T6 the tokens are not the last group: ${N6: -80}"

# ── T7: the console QA gate holds a replay onto a console-ui head ──
lg6_reset shadow
HC=$(lg6_head 101 console-ui/src/screens/Fx.js "export const fx = 1;") || bad "T7 setup: no head"
lgf_needs "101:$HC"; lgf_cmp "$HC" "$MEDF"; lg8_bv 101 APPROVE "$HC" 2026-10-15T10:00:00Z
printf 1 > "$FX/settings/lane.lead-review.lead_review_console_qa_gate"
prior MERGE; cls "$HC" "replay main-merge"
lwf_tick
[ "$(replay_posts)" = 0 ] && ok || bad "T7 a replay was posted: $(cat "$T/log/lv")"
grep -q "example-org/cromford#101 @${HC:0:12}: no lead MERGE replay from $G12 (console QA: MISSING); full review" "$L" \
  && ok || bad "T7 no hold line: $(cat "$L")"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "T7 jobs=$(lgf_jobs 101)"

# ── T8: the replay post fails: held ──
one shadow "$HA" "$MEDF"; prior MERGE; cls "$HA" "replay main-merge"; printf 1 > "$FX/lvrc"
lwf_tick
[ "$(replay_posts)" = 1 ] && ok || bad "T8 replay posts=$(replay_posts)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "T8 a job after a failed replay post"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "T8 summary: $(lwf_summary)"

# ── T9: the replay carries the replayed row's mode ──
one shadow "$HA" "$MEDF"; prior MERGE intent; cls "$HA" "replay main-merge"
lwf_tick
grep -q "^post example-org/cromford 101 $HA MERGE --source lead .*--note lead-replay:$G12 how:main-merge --review-mode intent$" "$T/log/lv" \
  && ok || bad "T9 intent argv: $(cat "$T/log/lv" 2>/dev/null)"
one shadow "$HA" "$MEDF"; prior MERGE; cls "$HA" "replay main-merge"
lwf_tick
grep -q "^post example-org/cromford 101 $HA MERGE --source lead .*--note lead-replay:$G12 how:main-merge --review-mode full$" "$T/log/lv" \
  && ok || bad "T9 full argv: $(cat "$T/log/lv" 2>/dev/null)"

# ── T10: the review-tier markers go after 7 days ──
one shadow "$HA" "$MEDF"
mkdir -p "$ST"
OLDM="$ST/review-tier-example-org_cromford-998-$A12"; NEWM="$ST/review-tier-example-org_cromford-997-$A12"
printf 'review-tier:low review-mode:full' > "$OLDM"; touch -d '8 days ago' "$OLDM"
printf 'review-tier:low review-mode:full' > "$NEWM"
lwf_tick
[ ! -e "$OLDM" ] && ok || bad "T10 an 8-day-old review-tier marker was kept: $(cat "$L")"
[ -e "$NEWM" ] && ok || bad "T10 a fresh review-tier marker was deleted"

# ── M1: a mutation: no token field, no tokens ──
G60="$H/bin/lib/lead-gates.d/60-risk.sh"
# The mutant keeps the original beside it (sed -i.orig) and is restored with mv.
sed -i.orig 's/^lg_field_review_tokens()/lg_unused_review_tokens()/' "$G60"
if cmp -s "$G60" "$G60.orig"; then bad "M1 the mutation did not apply (no lg_field_review_tokens in gate 60)"
else
  one shadow "$HA" "$MEDF"; printf intent > "$FX/settings/risk_tier.medium_mode"
  lwf_tick
  [[ "$(lg8_notes 101)" != *"review-tier:"* ]] && ok || bad "M1 the mutant still sent tokens: $(lg8_notes 101)"
fi
mv "$G60.orig" "$G60"

echo "lead-gates-tier-notes.bh-5878: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

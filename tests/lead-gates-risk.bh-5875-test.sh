#!/bin/bash
# tests/lead-gates-risk.bh-5875-test.sh — BH-5875 (BH-5870.2): gates 4 (the
# risk tier, BH-5022, with the rules-text lane of BH-5325) and 6 (the JEV
# shadow, BH-5024) of the enqueue, as the worklist gate
# bin/lib/lead-gates.d/60-risk.sh. Every case drives bin/lead-review.sh tick
# WHOLE over the worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh
# plus tests/lib/lead-gates-fixture.bh-5875.sh).
#   R1   low + enforce: one lead-verdict post (--source risk-tier --reviewer
#        risk-tier:box-demo), no job, skipped=1; R1b a second tick
#        reuses risk.tsv (no second POST /api/risk-tiers).
#   R2   medium + enforce, grace 0: a job.
#   R3   low + shadow: a `WOULD sign off` line, a job, no post.
#   R4   the POST /api/risk-tiers body: its keys and values.
#   R5   lead-verdict rc 1: held, no `signed off` line, no job.
#   R5b  rc 4: rc 12 and the risk-pub marker; R5c rc 3: held; R5d rc 5: a
#        withheld line in risk.tsv and a job.
#   R6   pulls/<n> 500: held.
#   R7   a lead-authored medium: a `lead` risk.tsv line, no risk-tiers POST, a job.
#   R8   a lead-authored rules-text head whose render check fails: a job.
#   R9   a lead-authored rules-text low, render ok: reviewer
#        risk-tier:rules-text:box-demo, no job.
#   R11  bin/lib/risk-tier.sh absent: a job.
#   R12  the mode row 500: no lead-verdict call, a job.
#   R13  jev_risk.mode=shadow: one `jev shadow` line, the sign-off unchanged.
#   R14  jev_risk.max_per_tick=1, two new heads: one ask, one `not asked` line.
#   R15  a compare with no files list: `unclassified` in risk.tsv, a job.
#   R16  lead_pr_authors unreadable: not classified, a job.
#   R17  a stored lead-route silence note (gate 30 gone): reviewed, no post.
#   M1   60-risk.sh removed: the R1 head gets a job and no post (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-risk.bh-5875-test.sh
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
for f in "$DIR/bin/lib/lead-gates.d/60-risk.sh" "$DIR/bin/lib/lead-gates-compare.sh" "$DIR/bin/lib/risk-tier.sh" "$DIR/bin/lib/rules-render-head.sh" "$DIR/bin/lib/ticket-ownership.sh"; do
  [ -r "$H/${f#"$DIR"/}" ] && ok || bad "setup: the closure did not install ${f#"$DIR"/}"
done
HA=$(printf '%040d' 101); A12=${HA:0:12}
HB=$(printf '%040d' 102)
HM=$(printf '%040d' 104)
RISK="$H/state/lead-review-enqueue/risk.tsv"
LOWF='[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
MEDF='[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
RULESF='[["rules/topics/12-x.md","added",12,0,"@@ -0,0 +1 @@\n+rule"],["rules/CLAUDE.md","modified",8,0,"@@ -1 +1 @@\n+rule"]]'
# A real rules-text head, so rrh_check's fetch and archive run on it.
mkdir -p "$W/rules/topics"; echo rule > "$W/rules/topics/12-x.md"; echo rule > "$W/rules/CLAUDE.md"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm rules
HR=$(git -C "$W" rev-parse HEAD); git -C "$W" push -q "$O" "HEAD:refs/pull/103/head"
summ() { lwf_summary; }
signed_lines() { lwf_cnt 'signed off by risk-tier' "$L"; }
one() { # one <mode> <pr> <head> <files>: one worklist head
  lgf_reset "$1"; lgf_needs "$2:$3"; lgf_cmp "$3" "$4"
}

# ── R1: low + enforce: signed off, no job ──
one enforce 101 "$HA" "$LOWF"
lwf_tick
[ "$(lgf_signed 101)" = 1 ] && ok || bad "R1 sign-offs=$(lgf_signed 101): $(cat "$L")"
# TEST-CHANGE BH-5878: the sign-off carries the BH-6967 tier and mode, as the enqueue's did.
grep -q "^post example-org/cromford 101 $HA MERGE --source risk-tier --reviewer risk-tier:box-demo --note low risk: docs, screens or new tests only, 3 lines --review-tier low --review-mode risk-tier$" "$T/log/lv" \
  && ok || bad "R1 lead-verdict argv: $(cat "$T/log/lv" 2>/dev/null)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "R1 a lead_review job"
[[ "$(summ)" == *" skipped=1 "* && "$(summ)" == *" started=0 "* ]] && ok || bad "R1 summary: $(summ)"
[ "$(signed_lines)" = 1 ] && ok || bad "R1 signed lines=$(signed_lines)"
[ "$(awk -F'\t' -v h="$HA" '$4 == h {print $5}' "$RISK" 2>/dev/null)" = low ] && ok || bad "R1 risk.tsv: $(cat "$RISK" 2>/dev/null)"
[ "$(lgf_rt_posts)" = 1 ] && ok || bad "R1 risk-tiers POSTs=$(lgf_rt_posts)"
# R1b: the next tick reads the tier back: no second risk-tiers POST
lwf_tick
[ "$(lgf_rt_posts)" = 1 ] && ok || bad "R1b risk-tiers POSTs after 2 ticks=$(lgf_rt_posts)"
[ "$(awk -F'\t' -v h="$HA" '$4 == h' "$RISK" | wc -l | tr -d ' ')" = 1 ] && ok || bad "R1b risk.tsv lines: $(cat "$RISK")"

# ── R2: medium + enforce, grace 0: reviewed ──
one enforce 104 "$HM" "$MEDF"; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "R2 no job for a medium head with grace 0: $(cat "$L")"
[ "$(lgf_lv)" = 0 ] && ok || bad "R2 a lead-verdict call"
grep -q "#104 @${HM:0:12}: risk tier medium" "$L" && ok || bad "R2 no medium line"

# ── R3: low + shadow: WOULD, reviewed ──
one shadow 101 "$HA" "$LOWF"
lwf_tick
grep -q "#101 @$A12: risk-tier WOULD sign off (low risk: " "$L" && ok || bad "R3 no WOULD line: $(cat "$L")"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "R3 no job under shadow"
[ "$(lgf_lv)" = 0 ] && ok || bad "R3 a lead-verdict call under shadow"
RB=$(grep '^POST /api/risk-tiers ' "$T/log/worker" | sed 's/^POST \/api\/risk-tiers //')
[ "$(jq -r '[.mode,.action] | join(" ")' <<<"$RB")" = "shadow would-sign-off" ] && ok || bad "R3 body: $RB"

# ── R4: the risk-tiers body: its keys and values ──
one enforce 101 "$HA" "$LOWF"
lwf_tick
B_D=$(grep '^POST /api/risk-tiers ' "$T/log/worker" | sed 's/^POST \/api\/risk-tiers //')
[ "$(jq -c 'keys' <<<"$B_D")" = '["action","files","head_sha","lines","mode","pr","project","reasons","repo","tier"]' ] && ok || bad "R4 keys: $B_D"
[ "$(jq -r '.repo' <<<"$B_D")" = example-org/cromford ] && ok || bad "R4 repo: $B_D"
[ "$(jq -c '.pr' <<<"$B_D")" = 101 ] && ok || bad "R4 pr: $B_D"
[ "$(jq -r '.head_sha' <<<"$B_D")" = "$HA" ] && ok || bad "R4 head_sha: $B_D"
[ "$(jq -r '.tier' <<<"$B_D")" = low ] && ok || bad "R4 tier: $B_D"
[ "$(jq -r '.mode' <<<"$B_D")" = enforce ] && ok || bad "R4 mode: $B_D"
[ "$(jq -r '.action' <<<"$B_D")" = sign-off ] && ok || bad "R4 action: $B_D"
[ "$(jq -c '.lines' <<<"$B_D")" = 3 ] && ok || bad "R4 lines: $B_D"
[ "$(jq -c '.files' <<<"$B_D")" = 1 ] && ok || bad "R4 files: $B_D"
[ "$(jq -r '.project' <<<"$B_D")" = cromford ] && ok || bad "R4 project: $B_D"

# ── R5: the post fails: held, never signed ──
one enforce 101 "$HA" "$LOWF"; echo 1 > "$FX/lvrc"
lwf_tick
[ "$(lgf_lv)" = 1 ] && ok || bad "R5 lead-verdict calls=$(lgf_lv)"
[ "$(signed_lines)" = 0 ] && ok || bad "R5 a signed line after a failed post"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "R5 a job after a failed post"
[[ "$(summ)" == *" held=1"* && "$(summ)" == *" skipped=0 "* ]] && ok || bad "R5 summary: $(summ)"
grep -q "#101 @$A12: risk-tier sign-off not recorded (post rc 1" "$L" && ok || bad "R5 line: $(cat "$L")"
# R5b: rc 4: decided, the risk-pub marker for the enqueue's retry
one enforce 101 "$HA" "$LOWF"; echo 4 > "$FX/lvrc"
lwf_tick
[[ "$(summ)" == *" skipped=1 "* ]] && ok || bad "R5b summary: $(summ)"
[ "$(cat "$H/state/lead-review-enqueue/risk-pub-example-org_cromford-101-$A12" 2>/dev/null)" = "low risk: docs, screens or new tests only, 3 lines" ] \
  && ok || bad "R5b risk-pub marker: $(ls "$H/state/lead-review-enqueue")"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "R5b a job"
# R5c: rc 3 (head moved): held
one enforce 101 "$HA" "$LOWF"; echo 3 > "$FX/lvrc"
lwf_tick
[[ "$(summ)" == *" held=1"* ]] && ok || bad "R5c summary: $(summ)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "R5c a job"
# R5d: rc 5 (withheld): a withheld line, reviewed
one enforce 101 "$HA" "$LOWF"; echo 5 > "$FX/lvrc"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "R5d no job after a withheld sign-off: $(cat "$L")"
[ "$(awk -F'\t' -v h="$HA" '$4 == h && $5 == "withheld"' "$RISK" | wc -l | tr -d ' ')" = 1 ] && ok || bad "R5d risk.tsv: $(cat "$RISK")"

# ── R6: the PR read fails: held ──
one enforce 101 "$HA" "$LOWF"; : > "$FX/ghfail.101"
lwf_tick
[[ "$(summ)" == *" held=1"* ]] && ok || bad "R6 summary: $(summ)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "R6 a job on an unreadable PR"
[ "$(lgf_lv)" = 0 ] && ok || bad "R6 a lead-verdict call"

# ── R7: a lead-authored medium: `lead`, no POST, reviewed ──
one enforce 104 "$HM" "$MEDF"; echo lead-bot > "$FX/author.104"
lwf_tick
[ "$(awk -F'\t' -v h="$HM" '$4 == h {print $5}' "$RISK" 2>/dev/null)" = lead ] && ok || bad "R7 risk.tsv: $(cat "$RISK" 2>/dev/null)"
[ "$(lgf_rt_posts)" = 0 ] && ok || bad "R7 a risk-tiers POST for a lead PR"
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "R7 no job: $(cat "$L")"

# ── R8: a lead rules-text head, render check fails: reviewed ──
one enforce 103 "$HR" "$RULESF"; echo lead-bot > "$FX/author.103"; echo 1 > "$FX/renderrc"
lwf_tick
[ "$(lgf_jobs 103)" = 1 ] && ok || bad "R8 no job: $(cat "$L")"
[ "$(lgf_lv)" = 0 ] && ok || bad "R8 a lead-verdict call"

# ── R9: a lead rules-text low, render ok: signed as rules-text ──
one enforce 103 "$HR" "$RULESF"; echo lead-bot > "$FX/author.103"
lwf_tick
grep -q "^post example-org/cromford 103 $HR MERGE --source risk-tier --reviewer risk-tier:rules-text:box-demo --note low risk: rules-text:" "$T/log/lv" \
  && ok || bad "R9 lead-verdict argv: $(cat "$T/log/lv" 2>/dev/null) :: $(cat "$L")"
[ "$(lgf_jobs 103)" = 0 ] && ok || bad "R9 a job"

# ── R11: no risk-tier lib: reviewed ──
mv "$H/bin/lib/risk-tier.sh" "$T/rt.off"
one enforce 101 "$HA" "$LOWF"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "R11 no job without risk-tier.sh: $(cat "$L")"
[ "$(lgf_lv)" = 0 ] && ok || bad "R11 a lead-verdict call"
mv "$T/rt.off" "$H/bin/lib/risk-tier.sh"

# ── R12: the mode row unreadable: off, reviewed ──
one enforce 101 "$HA" "$LOWF"; echo FAIL > "$FX/settings/risk_tier.mode.example-org.cromford"
lwf_tick
[ "$(lgf_lv)" = 0 ] && ok || bad "R12 a lead-verdict call on an unreadable mode"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "R12 no job"
grep -q "example-org/cromford risk tier: the risk_tier.mode.example-org.cromford row could not be read; off this tick" "$L" && ok || bad "R12 line: $(cat "$L")"

# ── R13: the JEV shadow: one line, the sign-off unchanged ──
cat > "$H/bin/jev-risk.sh" <<EOF
#!/bin/bash
printf '%s|%s\n' "\$JEV_CALLER" "\$*" >> "$T/log/jev"
printf 'ok\tlow\t0.10\t-\tfixture\n'
EOF
chmod +x "$H/bin/jev-risk.sh"
one enforce 101 "$HA" "$LOWF"; echo shadow > "$FX/settings/jev_risk.mode"
lwf_tick
[ "$(lwf_cnt . "$T/log/jev")" = 1 ] && ok || bad "R13 jev asks=$(lwf_cnt . "$T/log/jev")"
grep -q "^shadow:box-demo|ask example-org/cromford 101 $HA low " "$T/log/jev" && ok || bad "R13 jev argv: $(cat "$T/log/jev")"
grep -q "#101 @$A12: jev shadow ok low 0.10 fixture (rule tier low); shadow only, nothing changed" "$L" && ok || bad "R13 line: $(cat "$L")"
[ "$(lgf_signed 101)" = 1 ] && ok || bad "R13 the sign-off changed"
# ── R14: one ask a tick ──
one enforce 101 "$HA" "$LOWF"; lgf_needs "101:$HA" "102:$HB"; lgf_cmp "$HB" "$LOWF"
echo shadow > "$FX/settings/jev_risk.mode"; echo 1 > "$FX/settings/jev_risk.max_per_tick"
lwf_tick
[ "$(lwf_cnt . "$T/log/jev")" = 1 ] && ok || bad "R14 jev asks=$(lwf_cnt . "$T/log/jev")"
[ "$(lwf_cnt 'jev shadow not asked (jev_risk.max_per_tick=1 reached this tick)' "$L")" = 1 ] && ok || bad "R14 not-asked lines: $(cat "$L")"
[ "$(lgf_signed 101)$(lgf_signed 102)" = 11 ] && ok || bad "R14 sign-offs: $(cat "$T/log/lv")"
rm -f "$H/bin/jev-risk.sh"

# ── R15: no files list: unclassified, reviewed ──
lgf_reset enforce; lgf_needs "101:$HA"
jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}]}' > "$FX/cmp.$HA"
lwf_tick
[ "$(awk -F'\t' -v h="$HA" '$4 == h {print $5}' "$RISK" 2>/dev/null)" = unclassified ] && ok || bad "R15 risk.tsv: $(cat "$RISK" 2>/dev/null)"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "R15 no job"
[ "$(lgf_lv)" = 0 ] && ok || bad "R15 a lead-verdict call"

# ── R16: lead_pr_authors unreadable: not classified, reviewed ──
one enforce 101 "$HA" "$LOWF"; echo FAIL > "$FX/settings/lead_pr_authors"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "R16 no job"
[ "$(lgf_lv)" = 0 ] && ok || bad "R16 a lead-verdict call"
grep -q "#101 @$A12: risk tier skipped (lead_pr_authors row unreadable)" "$L" && ok || bad "R16 line: $(cat "$L")"

# ── R17: a stored lead-route note, gate 30 gone: reviewed, not signed ──
# TEST-CHANGE BH-5878: no enqueue request carries the note any more, so the
# head is not held for one: the review starts (the note rides in its notes).
mv "$GD/30-silence.sh" "$T/30.off"
one enforce 101 "$HA" "$LOWF"
mkdir -p "$H/state/lead-review-enqueue/silence"
echo "silence markers for the lead to judge (BH-5797): x" > "$H/state/lead-review-enqueue/silence/note-example-org_cromford-101-$A12"
lwf_tick
[ "$(lgf_lv)" = 0 ] && ok || bad "R17 a lead-verdict call with a lead note"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "R17 no job: $(summ)"
mv "$T/30.off" "$GD/30-silence.sh"

# ── M1: no risk gate: the R1 head is reviewed, not signed ──
mv "$GD/60-risk.sh" "$T/60.off"
one enforce 101 "$HA" "$LOWF"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "M1 no job with 60-risk.sh gone"
[ "$(lgf_lv)" = 0 ] && ok || bad "M1 a lead-verdict call with 60-risk.sh gone"
mv "$T/60.off" "$GD/60-risk.sh"

echo "lead-gates-risk.bh-5875: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

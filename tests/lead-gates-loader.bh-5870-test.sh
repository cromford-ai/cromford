#!/bin/bash
# tests/lead-gates-loader.bh-5870-test.sh — BH-5873 (BH-5870.0): the gate
# loader bin/lib/lead-gates.sh and its first gate,
# bin/lib/lead-gates.d/15-lead-lane-commit.sh (the enqueue's Lead-Lane skip,
# ported). Every case drives bin/lead-review.sh tick WHOLE over the worklist
# fixture (tests/lib/lead-worklist-fixture.bh-4956.sh); stub gate files are
# written into the scratch harness's bin/lib/lead-gates.d/.
#   G1-G4   a gate answering 10 / 11 / 12 / 99: no lead_review job opens;
#           10 and 12 count as skipped, 11 and any other rc as held=.
#   G5      every gate 0 and lg_field_stub_key printing v1: one job, its meta
#           carries stub_key; with no field function the job has no meta.
#   G6      lg_post runs once, after the job POST and the /start; lg_tick runs
#           once a tick; a failing hook is one log line and the review starts.
#   G6b     /start refused (a live holder): lg_post does not run.
#   G7      bin/lib/lead-gates.sh missing: no worklist item starts, one log
#           line, and a request row in the same tick IS reviewed.
#   G8      a field function failing: no job, `gate fields unreadable`.
#   G9      lead-gates.d missing, empty, or a gate file that fails to source:
#           the head is held, one log line.
#   G10     gates run in FILENAME order, not function-name order.
#   G11     LG_MODE outside full|delta|replay after the gates: held.
#   G12     LEAD_REVIEW_WORKLIST=0: no gate code runs; the request row is reviewed.
#   L1-L8b  the Lead-Lane gate (see each case). L8/L8b: the compare base is
#           the PR's own base (pulls/<n> .base.ref), as the enqueue's gate 12.
#   P1      the committed protected globs (catalog/lead-protected-paths.seed.tsv,
#           BH-4148) protect the lib and every gate file.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-loader.bh-5870-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
S12="${SHA:0:12}"
SHA2=$(printf '%040d' 2); S2="${SHA2:0:12}"
GD="$H/bin/lib/lead-gates.d"
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
[ -r "$GD/15-lead-lane-commit.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/15-lead-lane-commit.sh"

# The fixture's lane-alert, plus a failure switch ($FX/alertfail) for L7.
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
[ -e "$FX/alertfail" ] && exit 1
printf '%s\n' "\$*" >> "$T/log/lane-alert"
exit 0
EOF
chmod +x "$H/bin/lane-alert.sh"

# reset: the fixture's reset, plus the gate dir back to the shipped gate only
# and the enqueue's alert markers gone.
reset() {
  lwf_reset
  [ -e "$H/bin/lib/lead-gates.sh.off" ] && mv "$H/bin/lib/lead-gates.sh.off" "$H/bin/lib/lead-gates.sh"
  [ -e "$GD.off" ] && { scratch_rm "$GD"; mv "$GD.off" "$GD"; }
  [ -e "$T/lead-lane.off" ] && mv "$T/lead-lane.off" "$GD/15-lead-lane-commit.sh"
  find "$GD" -mindepth 1 -maxdepth 1 -type f ! -name '15-lead-lane-commit.sh' -delete
  scratch_rm "$H/state/lead-review-enqueue"
}
gate() { printf '%s\n' "$2" > "$GD/$1"; }       # gate <file> <body>
jobs_for() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
posts() { lwf_cnt '^POST /api/jobs .*"kind":"lead_review"' "$T/log/worker"; }
summ() { lwf_summary; }
# two worklist heads: 101 on $SHA, 102 on $SHA2
two_heads() {
  jq -nc --arg a "$SHA" --arg b "$SHA2" '[
    {repo:"example-org/demo-os", number:101, url:"https://github.com/example-org/demo-os/pull/101", head:$a, hotfix:0, nudged:0, approved_at:"2026-10-10T03:00:00Z"},
    {repo:"example-org/demo-os", number:102, url:"https://github.com/example-org/demo-os/pull/102", head:$b, hotfix:0, nudged:0, approved_at:"2026-10-10T03:00:01Z"}]' \
    > "$FX/needs.example-org_demo-os.json"
  echo "$SHA2" > "$FX/head.102"
}
# cmp_msg <head> <parents> <message> — the compare answer for <head>: one commit
cmp_msg() {
  jq -nc --argjson p "$2" --arg m "$3" '{total_commits:1, commits:[{parents:[range(0; $p) | {sha:"p"}], commit:{message:$m}}]}' > "$FX/cmp.$1"
}
row_102() { # a requested row r-102 on $SHA2
  jq -nc --arg s "$SHA2" '[{id:"r-102", repo:"example-org/demo-os", pr:102, head_sha:$s, status:"requested",
    created_at:"2026-10-10 03:00:00", scope_notes:null, requested_by:"lead-verdict"}]' > "$FX/rows.json"
  echo "$SHA2" > "$FX/head.102"
}
ALERT_TEXT="example-org/demo-os#102 @$S2 carries a Lead-Lane: commit, so the lead lane will not verdict its own work. To ask anyway: bin/lead-verdict.sh request example-org/demo-os 102 $SHA2 --notes \"...\""
MARK="$H/state/lead-review-enqueue/alerted-lead-self-example-org_demo-os-102-$S2"

# ── G1: a gate answers 10 (skip) ──
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_gate_stub() { return 10; }'
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G1 lead_review jobs opened=$(posts) (want 0): $(cat "$L")"
[ "$(lwf_agents)" = 0 ] && ok || bad "G1 agent calls=$(lwf_agents)"
[[ "$(summ)" == *" skipped=1 "* ]] && ok || bad "G1 summary: $(summ)"

# ── G2: a gate answers 11 (hold) ──
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_gate_stub() { return 11; }'
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G2 jobs opened=$(posts)"
[[ "$(summ)" == *" held=1"* && "$(summ)" == *" deferred=0 "* ]] && ok || bad "G2 summary: $(summ)"

# ── G3: a gate answers 12 (decided) ──
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_gate_stub() { return 12; }'
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G3 jobs opened=$(posts)"
[[ "$(summ)" == *" skipped=1 "* && "$(summ)" == *" held=0"* ]] && ok || bad "G3 summary: $(summ)"

# ── G4: a gate answers 99 ──
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_gate_stub() { return 99; }'
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G4 jobs opened=$(posts)"
grep -q 'gate lg_gate_stub answered rc 99; held' "$L" && ok || bad "G4 no rc line: $(cat "$L")"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "G4 summary: $(summ)"

# ── G5: every gate 0, a field function: one job, meta carries the field ──
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_gate_stub() { return 0; }
lg_field_stub_key() { echo v1; }'
lwf_tick
[ "$(posts)" = 1 ] && ok || bad "G5 jobs opened=$(posts) (want 1): $(cat "$L")"
m=$(grep '^POST /api/jobs .*"kind":"lead_review"' "$T/log/worker" | sed 's/^POST \/api\/jobs //' | jq -r '.meta // empty' | jq -r '.stub_key // empty' 2>/dev/null)
[ "$m" = v1 ] && ok || bad "G5 job meta stub_key='$m': $(grep '^POST /api/jobs' "$T/log/worker")"
[ "$(lwf_agents)" = 1 ] && ok || bad "G5 agent calls=$(lwf_agents)"
grep -q "compare/main\\.\\.\\.$SHA" "$T/log/gh" && ok || bad "G5 the Lead-Lane gate made no compare read: $(cat "$T/log/gh")"
# G5b: no field function, no meta key on the job
reset; lwf_needs example-org/demo-os 101
lwf_tick
[ "$(posts)" = 1 ] && ok || bad "G5b jobs opened=$(posts)"
grep -q '"meta"' <<<"$(grep '^POST /api/jobs .*"kind":"lead_review"' "$T/log/worker")" && bad "G5b a meta key with no field function" || ok

# ── G6: lg_post after the job POST and the /start; lg_tick once a tick ──
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh "lg_post_stub() { echo \"LGPOST \$1#\$2\" >> '$T/log/worker'; }
lg_tick_stub() { echo \"LGTICK \$1\" >> '$T/log/ticks'; }"
lwf_tick
[ "$(lwf_cnt '^LGPOST' "$T/log/worker")" = 1 ] && ok || bad "G6 LGPOST lines=$(lwf_cnt '^LGPOST' "$T/log/worker")"
lp=$(grep -n '^LGPOST' "$T/log/worker" | cut -d: -f1 | head -1)
lj=$(grep -n '^POST /api/jobs .*"kind":"lead_review"' "$T/log/worker" | cut -d: -f1 | head -1)
ls=$(grep -n '^POST /api/lead-reviews/start ' "$T/log/worker" | cut -d: -f1 | head -1)
[ -n "$lp" ] && [ -n "$lj" ] && [ -n "$ls" ] && [ "$lp" -gt "$lj" ] && [ "$lp" -gt "$ls" ] && ok \
  || bad "G6 order: LGPOST line=$lp job line=$lj start line=$ls"
grep -q '^LGPOST example-org/demo-os#101$' "$T/log/worker" && ok || bad "G6 lg_post args: $(grep LGPOST "$T/log/worker")"
[ "$(cat "$T/log/ticks" 2>/dev/null)" = "LGTICK example-org/demo-os" ] && ok || bad "G6 tick hook lines: '$(cat "$T/log/ticks" 2>/dev/null)'"
lwf_tick
[ "$(lwf_cnt '^LGTICK' "$T/log/ticks")" = 2 ] && ok || bad "G6 tick hook after 2 ticks=$(lwf_cnt '^LGTICK' "$T/log/ticks")"
# G6c: a failing tick hook and a failing post hook are one log line each; the review still runs
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_post_stub() { return 5; }
lg_tick_stub() { return 4; }'
lwf_tick
grep -q 'lg_tick_stub answered rc 4' "$L" && ok || bad "G6c no tick-hook line: $(cat "$L")"
grep -q 'lg_post_stub answered rc 5' "$L" && ok || bad "G6c no post-hook line"
[ "$(lwf_agents)" = 1 ] && ok || bad "G6c agent calls=$(lwf_agents) (want 1)"

# ── G6b: /start refused (a live holder): no lg_post ──
reset; lwf_needs example-org/demo-os 101
echo live > "$FX/start.101.$S12.force"
gate 50-stub.sh "lg_post_stub() { echo LGPOST >> '$T/log/worker'; }"
lwf_tick
grep -q '^POST /api/lead-reviews/start ' "$T/log/worker" && ok || bad "G6b no /start call"
[ "$(lwf_cnt '^LGPOST' "$T/log/worker")" = 0 ] && ok || bad "G6b lg_post ran after a refused /start"

# ── G7: the lib missing: no worklist item, one line, the request row runs ──
reset; lwf_needs example-org/demo-os 101
lwf_rows requested 5
mv "$H/bin/lib/lead-gates.sh" "$H/bin/lib/lead-gates.sh.off"
lwf_tick
[ "$(jobs_for 101)" = 0 ] && ok || bad "G7 a job for the worklist item 101"
[ "$(lwf_cnt 'bin/lib/lead-gates.sh missing; no worklist item starts this tick' "$L")" = 1 ] && ok || bad "G7 missing lines: $(cat "$L")"
[ "$(lwf_cnt '^GET /api/pr-state/needs-review' "$T/log/worker")" = 0 ] && ok || bad "G7 the worklist was read"
[ "$(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)" = 5 ] && ok || bad "G7 agent calls: '$(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)' (want 5)"

# ── G8: a field function fails: no job ──
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_field_stub_key() { return 1; }'
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G8 jobs opened=$(posts)"
grep -q "skip lr-101-$S12: gate fields unreadable" "$L" && ok || bad "G8 no line: $(cat "$L")"

# ── G9: lead-gates.d missing / empty / a file that fails to source ──
reset; lwf_needs example-org/demo-os 101 102
mv "$GD" "$GD.off"
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G9 jobs opened=$(posts) with no gate dir"
[[ "$(summ)" == *" held=2"* ]] && ok || bad "G9 summary: $(summ)"
[ "$(lwf_cnt 'lead-gates.d' "$L")" = 1 ] && ok || bad "G9 gate-dir lines=$(lwf_cnt 'lead-gates.d' "$L"): $(cat "$L")"
reset; lwf_needs example-org/demo-os 101
mv "$GD/15-lead-lane-commit.sh" "$T/lead-lane.off"
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G9b jobs opened=$(posts) with an empty gate dir"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "G9b summary: $(summ)"
reset; lwf_needs example-org/demo-os 101 102
gate 50-broken.sh 'lg_gate_broken() { return 0; }
false'
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G9c jobs opened=$(posts) with a gate file that fails to source"
[[ "$(summ)" == *" held=2"* ]] && ok || bad "G9c summary: $(summ)"
[ "$(lwf_cnt '50-broken.sh' "$L")" = 1 ] && ok || bad "G9c lines naming the file=$(lwf_cnt '50-broken.sh' "$L")"

# ── G10: filename order, not function-name order ──
reset; lwf_needs example-org/demo-os 101
gate 05-a.sh "lg_gate_zz() { echo zz >> '$T/log/order'; }"
gate 90-b.sh "lg_gate_aa() { echo aa >> '$T/log/order'; }"
lwf_tick
[ "$(paste -sd' ' "$T/log/order" 2>/dev/null)" = "zz aa" ] && ok || bad "G10 order: '$(paste -sd' ' "$T/log/order" 2>/dev/null)' (want zz aa)"

# ── G11: LG_MODE ──
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_gate_stub() { LG_MODE=bogus; return 0; }'
lwf_tick
[ "$(posts)" = 0 ] && ok || bad "G11 jobs opened=$(posts) with LG_MODE=bogus"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "G11 summary: $(summ)"
grep -q "LG_MODE='bogus'" "$L" && ok || bad "G11 no LG_MODE line"
reset; lwf_needs example-org/demo-os 101
gate 50-stub.sh 'lg_gate_stub() { LG_MODE=delta; return 0; }'
lwf_tick
[ "$(posts)" = 1 ] && ok || bad "G11b jobs opened=$(posts) with LG_MODE=delta (want 1)"

# ── G12: the worklist off (the prod default): no gate code runs ──
reset; row_102
cmp_msg "$SHA2" 1 $'fix\n\nLead-Lane: lead-review'
gate 50-stub.sh "lg_tick_stub() { echo LGTICK >> '$T/log/ticks'; }"
LEAD_REVIEW_WORKLIST=0 lwf_tick
grep -q 'compare/' "$T/log/gh" 2>/dev/null && bad "G12 a compare read: $(grep compare "$T/log/gh")" || ok
[ -e "$T/log/ticks" ] && bad "G12 the tick hook ran" || ok
[ "$(lwf_cnt '^POST /api/lead-reviews/r-102/claim' "$T/log/worker")" = 1 ] && ok || bad "G12 r-102 not claimed: $(cat "$L")"

# ── L1: two heads, one carries a Lead-Lane commit: one review, one warn ──
reset; two_heads
cmp_msg "$SHA2" 1 $'fix\n\nLead-Lane: lead-review'
lwf_tick
[ "$(jobs_for 101)" = 1 ] && ok || bad "L1 jobs for 101=$(jobs_for 101): $(cat "$L")"
[ "$(jobs_for 102)" = 0 ] && ok || bad "L1 jobs for 102=$(jobs_for 102)"
[ "$(posts)" = 1 ] && ok || bad "L1 jobs opened=$(posts) (want 1)"
[ "$(lwf_cnt '\[skip lead-lane\]' "$L")" = 1 ] && ok || bad "L1 skip lines=$(lwf_cnt '\[skip lead-lane\]' "$L")"
grep -q "\[skip lead-lane\] example-org/demo-os#102 @$S2 carries a Lead-Lane: commit; not reviewed" "$L" && ok || bad "L1 skip line: $(grep 'skip lead-lane' "$L")"
[ "$(lwf_cnt . "$T/log/lane-alert")" = 1 ] && ok || bad "L1 lane-alert calls=$(lwf_cnt . "$T/log/lane-alert")"
[ "$(cat "$T/log/lane-alert" 2>/dev/null)" = "--severity warn --id lead-self-example-org_demo-os-102-$S2 lead-review-enqueue $ALERT_TEXT" ] && ok \
  || bad "L1 alert argv: $(cat "$T/log/lane-alert" 2>/dev/null)"
[ -e "$MARK" ] && ok || bad "L1 no alert marker at the enqueue's path"
[[ "$(summ)" == *" skipped=1 "* && "$(summ)" == *" held=0"* ]] && ok || bad "L1 summary: $(summ)"

# ── L2: the same heads on a second tick: no second warn, still no review ──
lwf_tick
[ "$(lwf_cnt '\[skip lead-lane\]' "$L")" = 1 ] && ok || bad "L2 skip lines after 2 ticks=$(lwf_cnt '\[skip lead-lane\]' "$L")"
[ "$(lwf_cnt . "$T/log/lane-alert")" = 1 ] && ok || bad "L2 lane-alert calls after 2 ticks=$(lwf_cnt . "$T/log/lane-alert")"
[ "$(jobs_for 102)" = 0 ] && ok || bad "L2 jobs for 102=$(jobs_for 102)"

# ── L2b: a marker the enqueue wrote stops the gate's warn ──
reset; two_heads
cmp_msg "$SHA2" 1 $'fix\n\nLead-Lane: lead-review'
mkdir -p "${MARK%/*}"; : > "$MARK"
lwf_tick
[ -e "$T/log/lane-alert" ] && bad "L2b a lane-alert call: $(cat "$T/log/lane-alert")" || ok
[ "$(lwf_cnt '\[skip lead-lane\]' "$L")" = 0 ] && ok || bad "L2b skip lines=$(lwf_cnt '\[skip lead-lane\]' "$L")"
[ "$(jobs_for 102)" = 0 ] && ok || bad "L2b 102 reviewed"
[[ "$(summ)" == *" skipped=1 "* ]] && ok || bad "L2b summary: $(summ)"

# ── L3a: a MERGE commit carrying Lead-Lane: is not a hit ──
reset; two_heads
cmp_msg "$SHA2" 2 $'Merge main\n\nLead-Lane: lead-review'
lwf_tick
[ "$(jobs_for 102)" = 1 ] && ok || bad "L3a jobs for 102=$(jobs_for 102) (want 1): $(cat "$L")"
[ -e "$T/log/lane-alert" ] && bad "L3a a lane-alert call" || ok
# ── L3b: Lead-Lane: inside a line, not at its start, is not a hit ──
reset; two_heads
cmp_msg "$SHA2" 1 $'fix\n\nsee Lead-Lane: x'
lwf_tick
[ "$(jobs_for 102)" = 1 ] && ok || bad "L3b jobs for 102=$(jobs_for 102) (want 1)"

# ── L4: the compare unreadable: held, no warn ──
reset; two_heads
: > "$FX/cmpfail.$SHA2"
lwf_tick
[ "$(jobs_for 102)" = 0 ] && ok || bad "L4 102 reviewed on an unreadable compare"
[ "$(jobs_for 101)" = 1 ] && ok || bad "L4 101 not reviewed"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "L4 summary: $(summ)"
grep -q "example-org/demo-os#102 @$S2: compare main...$S2 unreadable (rc 75, unreadable); held" "$L" && ok || bad "L4 no line: $(cat "$L")"
[ -e "$T/log/lane-alert" ] && bad "L4 a lane-alert call" || ok

# ── L5: a truncated compare (300 commits, 1 listed): held, no warn ──
reset; two_heads
jq -nc '{total_commits:300, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}]}' > "$FX/cmp.$SHA2"
lwf_tick
[ "$(jobs_for 102)" = 0 ] && ok || bad "L5 102 reviewed on a truncated compare"
[[ "$(summ)" == *" held=1"* ]] && ok || bad "L5 summary: $(summ)"
grep -q "example-org/demo-os#102 @$S2: compare main...$S2 unreadable (rc 0, truncated); held" "$L" && ok || bad "L5 no line: $(cat "$L")"
[ -e "$T/log/lane-alert" ] && bad "L5 a lane-alert call" || ok

# ── L6: a request row on a Lead-Lane head is reviewed (the human ask) ──
reset; two_heads; row_102
cmp_msg "$SHA2" 1 $'fix\n\nLead-Lane: lead-review'
lwf_tick
[ "$(lwf_cnt '^POST /api/lead-reviews/r-102/claim' "$T/log/worker")" = 1 ] && ok || bad "L6 r-102 not claimed: $(cat "$L")"
grep -q "compare/main\\.\\.\\.$SHA2" "$T/log/gh" && bad "L6 the gate ran on a request row" || ok
[ -e "$T/log/lane-alert" ] && bad "L6 a lane-alert call" || ok

# ── L7: the warn fails: no marker, no skip line, retried next tick ──
reset; two_heads
cmp_msg "$SHA2" 1 $'fix\n\nLead-Lane: lead-review'
: > "$FX/alertfail"
lwf_tick
[ -e "$MARK" ] && bad "L7 a marker after a failed warn" || ok
grep -q "lane-alert.sh failed for lead-self-example-org_demo-os-102-$S2; next tick retries" "$L" && ok || bad "L7 no failure line: $(cat "$L")"
[ "$(lwf_cnt '\[skip lead-lane\]' "$L")" = 0 ] && ok || bad "L7 a skip line after a failed warn"
[ "$(jobs_for 102)" = 0 ] && ok || bad "L7 102 reviewed"
rm -f "$FX/alertfail"
lwf_tick
[ "$(lwf_cnt . "$T/log/lane-alert")" = 1 ] && ok || bad "L7 the next tick did not warn"
[ -e "$MARK" ] && ok || bad "L7 no marker after the retried warn"

# ── L8: the PR's base unreadable (a 500, or a 200 with no base.ref): held, no compare ──
for fx in basefail basebad; do
  reset; two_heads
  : > "$FX/$fx.102"
  lwf_tick
  [ "$(jobs_for 102)" = 0 ] && ok || bad "L8 $fx: 102 reviewed with its base unreadable"
  [ "$(jobs_for 101)" = 1 ] && ok || bad "L8 $fx: 101 not reviewed (one PR's base read held another): $(cat "$L")"
  [[ "$(summ)" == *" held=1"* ]] && ok || bad "L8 $fx summary: $(summ)"
  grep -q "compare base of example-org/demo-os#102 unreadable (rc [0-9]*); @$S2 held" "$L" && ok || bad "L8 $fx no line: $(cat "$L")"
  grep -q "compare/[^ ]*\\.\\.\\.$SHA2" "$T/log/gh" && bad "L8 $fx a compare read for 102" || ok
done
# ── L8b: a stacked PR: the compare base is the PR's own base, not main ──
reset; two_heads
echo ticket/bh-5873 > "$FX/base.102"
lwf_tick
grep -q "^api -i -X GET repos/example-org/demo-os/pulls/102" "$T/log/gh" && ok || bad "L8b no pulls/102 read: $(cat "$T/log/gh")"
grep -q "compare/ticket%2Fbh-5873\\.\\.\\.$SHA2" "$T/log/gh" && ok || bad "L8b no compare on the PR base: $(grep compare "$T/log/gh")"
grep -q "compare/main\\.\\.\\.$SHA2" "$T/log/gh" && bad "L8b a compare on main for the stacked PR" || ok
grep -q "compare/main\\.\\.\\.$SHA" "$T/log/gh" && ok || bad "L8b 101 (base main) not compared on main"
[ "$(jobs_for 102)" = 1 ] && ok || bad "L8b jobs for 102=$(jobs_for 102) (want 1)"

# ── P1: the lead-protected catalog covers the lib and every gate file ──
p1=$(
  . "$LWF_SRC/bin/lib/lead-authority.sh" || exit 1
  # TEST-CHANGE BH-4148: the committed TSV is gone; the committed globs are the
  # seed file, which protects every path that has no lead_protected_paths row yet.
  globs=$(HARNESS="$LWF_SRC" _la_seed_floor example-org/cromford "")
  [ -n "$globs" ] || exit 1
  for f in bin/lib/lead-gates.sh bin/lib/lead-gates.d/15-lead-lane-commit.sh; do
    hit=0
    while IFS= read -r g; do _la_match "$f" "$g" && hit=1; done <<<"$globs"
    printf '%s=%s ' "$f" "$hit"
  done
)
[ "$p1" = "bin/lib/lead-gates.sh=1 bin/lib/lead-gates.d/15-lead-lane-commit.sh=1 " ] && ok || bad "P1 catalog matches: $p1"

echo "lead-gates-loader.bh-5870: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

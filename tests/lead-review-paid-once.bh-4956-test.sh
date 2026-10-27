#!/bin/bash
# tests/lead-review-paid-once.bh-4956-test.sh — BH-4956: a worklist head is paid
# for once. The dedup order before the agent call is: /start terminal done ->
# the job artifact, then the disk report -> <key>.empty -> the patch-same replay
# -> the lead_fp guard. bin/lead-review.sh tick runs WHOLE against a scratch
# harness (tests/lib/lead-worklist-fixture.bh-4956.sh).
#   P1  a second tick for the same (pr, sha): /start answers 409 terminal done,
#       0 more agent calls, and the summary says paid=1.
#   P2  the disk report for the key: 1 agent call in total over two ticks.
#   P3  <key>.empty: outcome=failed detail=empty, and 0 agent calls.
#   P4  a head that only merged main into a head the lead approved (patch-same):
#       0 agent calls, a done result with reviewer_model lead-replay and
#       report_ref lead-replay:<prev12>:<how>, and replayed=1. A head whose own
#       files changed (a `delta` class) is reviewed: 1 agent call. An earlier
#       lead BLOCK is never replayed (P4e): 1 agent call. A person's request
#       row is never replayed (P4f); the enqueue's own row is (P4g).
#   P5  the per-key lock held by another worker: no claim, no call. Two ticks
#       at once on one key: exactly 1 agent call.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-paid-once.bh-4956-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" LEAD_DELTA_REVIEW_MAX_LINES=50
S12=${SHA:0:12}
starts() { lwf_cnt '^POST /api/lead-reviews/start ' "$T/log/worker"; }

# ── P1: /start terminal done is paid ──
lwf_reset
lwf_needs example-org/demo-os 101
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "P1 tick 1 agent calls=$(lwf_agents)"
lwf_tick
[ "$(starts)" = 2 ] && ok || bad "P1 /start calls=$(starts) (want 2)"
[ "$(lwf_agents)" = 1 ] && ok || bad "P1 the second tick paid again: agent calls=$(lwf_agents)"
[[ "$(lwf_summary)" == *" paid=1 "* ]] && ok || bad "P1 summary: $(lwf_summary)"
grep -q "paid already lr-101-$S12: its request is done; no agent call" "$L" && ok || bad "P1 no paid line"

# ── P2: the disk report is paid ──
lwf_reset
lwf_needs example-org/demo-os 101
lwf_tick
rm -f "$FX/start.101.$S12"   # a fresh request row for the same head
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "P2 agent calls over two ticks=$(lwf_agents) (want 1)"
grep -q "reusing $H/state/lead-reviews/lr-101-$S12.md for lr-101-$S12; no agent call" "$L" && ok || bad "P2 no reuse line: $(cat "$L")"
[ "$(lwf_cnt '"outcome":"done"' "$T/log/worker")" = 2 ] && ok || bad "P2 done results=$(lwf_cnt '"outcome":"done"' "$T/log/worker") (want 2)"

# ── P3: <key>.empty is billed with no verdict ──
lwf_reset
lwf_needs example-org/demo-os 101
mkdir -p "$H/state/lead-reviews"; echo stub-model > "$H/state/lead-reviews/lr-101-$S12.empty"
lwf_tick
[ "$(lwf_agents)" = 0 ] && ok || bad "P3 agent calls=$(lwf_agents)"
grep -q "^POST /api/lead-reviews/s-101-$S12/result .*\"outcome\":\"failed\".*\"detail\":\"empty\"" "$T/log/worker" && ok || bad "P3 no failed/empty result: $(grep result "$T/log/worker")"

# ── P4: the patch-same replay ──
BASE=$(git -C "$W" rev-parse "$SHA~1")
gc() { git -C "$W" -c user.email=t@t -c user.name=t "$@"; }
gc checkout -q -b mainline "$BASE"; echo m > "$W/b.txt"; gc add b.txt; gc commit -qm "main moves"
NEWMAIN=$(gc rev-parse HEAD)
gc checkout -q -b prmerge "$SHA"; gc merge -q --no-edit mainline; H1=$(gc rev-parse HEAD)
gc checkout -q -b prdelta "$SHA"; echo three >> "$W/a.txt"; gc commit -qam "own change"; H2=$(gc rev-parse HEAD)
git -C "$W" push -q "$O" "$NEWMAIN:refs/heads/main" "$H1:refs/pull/201/head" "$H2:refs/pull/202/head"
lwf_reset
lwf_needs_at example-org/demo-os "$H1" 201
echo "$H1" > "$FX/head.201"
jq -nc --arg g "$SHA" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:"MERGE", note:"report:state/lead-reviews/x.md"}], truncated:false}' > "$FX/verdicts.json"
lwf_tick
[ "$(lwf_agents)" = 0 ] && ok || bad "P4 the rebound head was reviewed: agent calls=$(lwf_agents): $(cat "$L")"
R=$(grep "^POST /api/lead-reviews/s-201-${H1:0:12}/result " "$T/log/worker" | sed 's/^[^{]*//')
[ "$(jq -r '.outcome' <<<"$R")" = done ] && [ "$(jq -r '.verdict' <<<"$R")" = MERGE ] \
  && [ "$(jq -r '.reviewer_model' <<<"$R")" = lead-replay ] \
  && [ "$(jq -r '.report_ref' <<<"$R")" = "lead-replay:$S12:main-merge" ] && ok || bad "P4 replay result: $R"
[[ "$(lwf_summary)" == *" replayed=1 "* ]] && ok || bad "P4 summary: $(lwf_summary)"
grep -q '^POST /api/wakes/lane .*"kind":"lead-land"' "$T/log/worker" && ok || bad "P4 the replay did not ring lead-land"
# the negative: the PR's own file changed since the approved head
lwf_reset
lwf_needs_at example-org/demo-os "$H2" 202
echo "$H2" > "$FX/head.202"
jq -nc --arg g "$SHA" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:202, head_sha:$g, verdict:"MERGE", note:""}], truncated:false}' > "$FX/verdicts.json"
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "P4b a changed head was not reviewed: agent calls=$(lwf_agents)"
grep -q 'lead-replay' "$T/log/worker" && bad "P4b replayed a changed head" || ok
grep -q "lr-202-${H2:0:12}: no replay (since $S12: " "$L" && ok || bad "P4b no no-replay line: $(cat "$L")"
# an earlier row that is itself a replay is never the source of one
lwf_reset
lwf_needs_at example-org/demo-os "$H1" 201; echo "$H1" > "$FX/head.201"
jq -nc --arg g "$SHA" '{rows:[{id:9, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:"MERGE", note:"report:lead-replay:aaaaaaaaaaaa:main-merge"}], truncated:false}' > "$FX/verdicts.json"
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "P4c replayed from a replay: agent calls=$(lwf_agents)"
# an unreadable or truncated verdict list is a review
lwf_reset
lwf_needs_at example-org/demo-os "$H1" 201; echo "$H1" > "$FX/head.201"
jq -nc --arg g "$SHA" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:"MERGE", note:""}], truncated:true}' > "$FX/verdicts.json"
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "P4d replayed from a truncated list: agent calls=$(lwf_agents)"

# P4e (lead BLOCK at c4cd25de8): an earlier lead BLOCK is never replayed by the
# lane. A BLOCK leaves its own head only through the enqueue's BH-3930 rebound
# replay (bin/lead-review-enqueue.sh, BH-5294); a main-merge after a BLOCK, or a
# person's request, is reviewed by the model.
lwf_reset
lwf_needs_at example-org/demo-os "$H1" 201; echo "$H1" > "$FX/head.201"
jq -nc --arg g "$SHA" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:"BLOCK", note:"report:state/lead-reviews/x.md"}], truncated:false}' > "$FX/verdicts.json"
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "P4e a head after a BLOCK was not reviewed: agent calls=$(lwf_agents)"
grep -q 'lead-replay' "$T/log/worker" && bad "P4e replayed a BLOCK onto a new head: $(grep lead-replay "$T/log/worker")" || ok
grep -q "lr-201-${H1:0:12}: no replay (.*BLOCK" "$L" && ok || bad "P4e no no-replay line naming the BLOCK: $(grep 'no replay' "$L")"

# P4f (lead BLOCK at 3c76810ce): a person's request is never replayed. A
# request row on H1 (a main-merge of G, which the lead approved) filed by a
# person (requested_by is the box: lead-verdict.sh request, harness-ctl review)
# is reviewed by the model. The enqueue's own row on the same head (P4g) is
# still replayed (requested_by lead-review-enqueue:*, the rule at
# bin/lead-review.sh's replay).
p4row() { # p4row <requested_by>: one `requested` row for pr 201 at H1
  jq -nc --arg s "$H1" --arg by "$1" '[{id:"r-201", repo:"example-org/demo-os", pr:201, head_sha:$s, status:"requested",
    created_at:"2026-10-10 03:00:00", scope_notes:null, requested_by:$by}]' > "$FX/rows.json"
}
lwf_reset
echo "$H1" > "$FX/head.201"; p4row box-mac
jq -nc --arg g "$SHA" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:"MERGE", note:""}], truncated:false}' > "$FX/verdicts.json"
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "P4f a person's request was replayed: agent calls=$(lwf_agents): $(cat "$L")"
grep -q 'lead-replay' "$T/log/worker" && bad "P4f posted a lead-replay result for a person's request" || ok
grep -q "lr-201-${H1:0:12}: no replay (requested by box-mac, not the enqueue" "$L" && ok || bad "P4f no no-replay line: $(grep 'no replay' "$L")"
lwf_reset
echo "$H1" > "$FX/head.201"; p4row lead-review-enqueue:hub
jq -nc --arg g "$SHA" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:"MERGE", note:""}], truncated:false}' > "$FX/verdicts.json"
lwf_tick
[ "$(lwf_agents)" = 0 ] && ok || bad "P4g the enqueue's row was not replayed: agent calls=$(lwf_agents)"
grep -q "^POST /api/lead-reviews/r-201/result .*\"reviewer_model\":\"lead-replay\"" "$T/log/worker" && ok || bad "P4g no replay result: $(grep result "$T/log/worker")"

# ── P5: one worker per key ──
lwf_reset
lwf_needs example-org/demo-os 101
mkdir -p "$H/locks"
( exec 8>"$H/locks/lead-review-lr-101-$S12.lock"; flock -n 8 || exit 1; : > "$T/held"; exec sleep 30 ) & HOLD=$!
lwf_wait 5 test -e "$T/held" || bad "P5 could not hold the key lock"
lwf_tick
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; rm -f "$T/held"
[ "$(starts)" = 0 ] && [ "$(lwf_agents)" = 0 ] && ok || bad "P5 a claim under a held key lock: starts=$(starts) agents=$(lwf_agents)"
grep -q "skip lr-101-$S12: another worker holds locks/lead-review-lr-101-$S12.lock" "$L" && ok || bad "P5 no skip line: $(cat "$L")"
lwf_reset
lwf_needs example-org/demo-os 101
echo 2 > "$FX/sleep"
lwf_tick_bg; P1PID=$TICK_PID
( cd "$T" && HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/lead-review.sh" tick ) > "$T/out2" 2>&1
wait "$P1PID" 2>/dev/null
[ "$(lwf_agents)" = 1 ] && ok || bad "P5b two ticks at once: agent calls=$(lwf_agents) (want 1)"

echo "lead-review-paid-once.bh-4956: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

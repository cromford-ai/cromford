#!/bin/bash
# tests/lead-review-dedupe.bh-3930-test.sh — BH-3941 (BH-3930.4): a PR head buys
# ONE lead review. bin/lead-review.sh tick runs WHOLE in two sections, each
# against a scratch harness carrying the real jobs client and the real libs it
# sources ("$DIR/bin/lib/review-bought.sh" included in the first):
#
#   bin/lead-review.sh tick (D1-D3)
#     D1  tick 1 blocks inside its agent call; tick 2 exits 0 at once. Since
#         BH-6984 tick 1 releases locks/lead-review-tick.lock when its starts
#         close, so tick 2 is not skipped on it: it reaches the claim, and the
#         DB claim (job_open 409) refuses it (`skip <key>: `), never a wait.
#         One agent call, two job_opens (the second refused).
#     D2  tick 1 killed -9 (its whole process group): the lock is free, and the
#         next tick finishes from the stored lead_review_report artifact with no
#         agent call.
#     D3  both calls carry AGENT_CALL_GUARD_STAGE=lead-head and the per-head fp
#         lead:o/r#7@<sha>; the unknown-verdict retry is ...~noverdict.
# Stubbed: curl (the jobs worker), gh (REST reads) and bin/agent-call.sh.
# Dispatcher section (BH-5874): gate 3's BH-3930 rebound replay,
# bin/lib/lead-gates.d/50-replay-delta.sh (it reads bin/lib/patch-same.sh), on
# the worklist. Its post-rc, unreadable-history, no-G and already-replayed
# near misses are in tests/lead-gates-replay-dedupe.bh-8557-test.sh; the
# replay line and modes.tsv row in tests/lead-replay-merge-only.bh-5294-test.sh
# R1. bin/lead-review.sh
# tick runs WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh, with the real
# bin/lead-verdict.sh and the lead token on the box. G is the PR commit, H1 = G
# + a main merge (#201); the builder APPROVE is on G and head-bound
# reapproved@H1.
#   B1  the lead MERGEd G: one POST /api/verdicts, MERGE on H1, and no job.
#   B2  the lead BLOCKed G: one POST /api/verdicts with BLOCK, never MERGE.
#   B3  a lead row with a lead-replay: note is already on H1: no post, no job.
#   B4  (BH-8476) the lead BLOCK on G is retracted: no post, a full review job.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-dedupe.bh-3930-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
command -v setsid >/dev/null || { echo "FAIL: setsid missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/review-bought.sh bin/lib/patch-same.sh; do
  [ -f "$DIR/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# ═════════════════════════ part 1: bin/lead-review.sh ═════════════════════════
H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/lead-review.sh" "$H/bin/"
# TEST-CHANGE (BH-6293): bin/lead-review.sh loads its modules from bin/lib/lead-review/.
scratch_install_closure bin/lib/lead-review/load.sh "$H" >/dev/null || { echo "closure install of bin/lib/lead-review failed"; exit 1; }
# TEST-CHANGE (BH-7455): bin/lead-review.sh loads its optional libs from bin/lib/lead-review/libs.d/.
cp -R "$DIR/bin/lib/lead-review/libs.d" "$H/bin/lib/lead-review/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in env-path lead-reviews verdicts model-route verdict-parse gh-rest hub-box lane-gate review-bought review-pool lead-worklist; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"
done
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
printf 'demo-os o/r https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"

# origin with main + the PR head at refs/pull/7/head; the box's clone
O="$T/origin/demo-os.git"; W="$T/work/demo-os"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" commit -qam "pr change"; git -C "$W" push -q "$O" "HEAD:refs/pull/7/head"
git clone -q "$O" "$T/repos/demo-os"
SHA=$(git -C "$W" rev-parse HEAD); SHA12=${SHA:0:12}
KEY="lr-7-$SHA12"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs")
    st=\$(cat "$T/jobstate" 2>/dev/null)
    if [ "\$st" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "GET /api/jobs/job-7/artifacts") [ -f "$T/artifacts.json" ] && out=\$(cat "$T/artifacts.json") ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$SHA" '{head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
# The agent stub: records the guard env, says it started, and when $T/block
# exists waits (bounded) for $T/release — a lead review that outlives a tick.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"; n=\$(wc -l < "$T/log/agent-count")
printf '%s %s\n' "\${AGENT_CALL_GUARD_STAGE:-<unset>}" "\${AGENT_CALL_FP:-<unset>}" >> "$T/log/agent-fp"
: > "$T/started"
if [ -e "$T/block" ]; then for i in \$(seq 1 600); do [ -e "$T/release" ] && break; sleep 0.1; done; fi
if [ -f "$T/answer.\$n" ]; then cp "$T/answer.\$n" "\$5"; else cp "$T/answer" "\$5"; fi
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

LLOG="$H/logs/lead-review.log"
LOCK="$H/locks/lead-review-tick.lock"
reset1() {
  rm -f "$T/log"/* "$T"/{jobstate,block,release,started,artifacts.json,answer.*} "$LLOG"
  scratch_rm "$H/state/lead-reviews"
  jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"o/r",pr:7,head_sha:$s,scope_notes:"n",prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
  printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer"
}
tick1() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
opens() { grep -c '^POST /api/jobs ' "$T/log/worker" 2>/dev/null || true; }
# wait_for <path> — bounded poll for a marker file (never a bare sleep race)
wait_for() { local i; for i in $(seq 1 300); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }

# ── D1: a second tick while the first is still reviewing skips, never waits ──
reset1; : > "$T/block"
( cd "$T" && exec setsid bash "$H/bin/lead-review.sh" tick ) > "$T/out1" 2>&1 &
P1=$!
wait_for "$T/started" && ok || bad "D1 tick 1 never reached its agent call: $(cat "$T/out1" "$LLOG" 2>/dev/null)"
S0=$SECONDS; tick1; S1=$SECONDS
[ "$RC" -eq 0 ] && ok || bad "D1 tick 2 rc=$RC out=$(cat "$T/out")"
[ $((S1 - S0)) -lt 20 ] && ok || bad "D1 tick 2 took $((S1 - S0))s: it waited for tick 1"
[ -e "$T/release" ] && bad "D1 tick 1 released before tick 2 ran" || ok
grep -q "skip $KEY: " "$LLOG" && ok \
  || bad "D1 tick 2 was not refused by the job_open claim: $(cat "$LLOG")"
: > "$T/release"; wait "$P1"; RC1=$?
[ "$RC1" -eq 0 ] && ok || bad "D1 tick 1 rc=$RC1 out=$(cat "$T/out1")"
[ "$(agents)" = 1 ] && ok || bad "D1 agent called $(agents) time(s), want 1"
[ "$(opens)" = 2 ] && ok || bad "D1 job_open called $(opens) time(s), want 2 (tick 2's refused): $(cat "$T/log/worker")"
grep -q "done $KEY: VERDICT MERGE" "$LLOG" && ok || bad "D1 tick 1 did not finish: $(cat "$LLOG")"
# a later tick, with nothing running, is not skipped
rm -f "$LLOG"; tick1
grep -q 'tick skipped' "$LLOG" && bad "D1 a sequential tick was skipped: $(cat "$LLOG")" || ok
grep -q ' tick seen=' "$LLOG" && ok || bad "D1 the sequential tick wrote no summary: $(cat "$LLOG")"

# ── D2: the holder killed -9 frees the lock; the retry replays, no agent call ──
reset1; : > "$T/block"
( cd "$T" && exec setsid bash "$H/bin/lead-review.sh" tick ) > "$T/out1" 2>&1 &
P1=$!
wait_for "$T/started" && ok || bad "D2 tick 1 never reached its agent call"
kill -9 -- "-$P1" 2>/dev/null && ok || bad "D2 could not kill the process group of tick 1"
wait "$P1" 2>/dev/null
FREE=0; for i in $(seq 1 100); do flock -n "$LOCK" true 2>/dev/null && { FREE=1; break; }; sleep 0.1; done
[ "$FREE" = 1 ] && ok || bad "D2 the lock is still held after the holder was killed"
grep -q '/result' "$T/log/worker" && bad "D2 the killed tick posted a result" || ok
# what bin/jobs-watchdog.sh does to the job, and the report the job already stored
echo queued_for_retry > "$T/jobstate"; rm -f "$T/block" "$T/started"
BODY=$(printf '# Lead review %s (o/r#7 at %s)\n\n- verdict: MERGE\n- host suite: no host suite declared\n- reviewer model: stub-model\n\nFindings\n- none\n\nVERDICT: MERGE\n' "$KEY" "$SHA")
jq -nc --arg b "$BODY" --arg p "$H/state/lead-reviews/$KEY.md" \
  '{artifacts:[{artifact_kind:"lead_review_report", detail:({body:$b,path:$p,verdict:"MERGE"}|tojson)}]}' > "$T/artifacts.json"
tick1
[ "$RC" -eq 0 ] && ok || bad "D2 retry rc=$RC out=$(cat "$T/out")"
[ "$(agents)" = 1 ] && ok || bad "D2 the retry called the agent: $(agents) call(s), want the killed tick's 1"
grep -q 'tick skipped' "$LLOG" && bad "D2 the retry was skipped on a dead holder's lock" || ok
grep -q "reusing artifact lead_review_report for $KEY; no agent call" "$LLOG" && ok || bad "D2 no artifact replay: $(cat "$LLOG")"
grep -q '^POST /api/lead-reviews/lr-1/result .*"outcome":"done".*"verdict":"MERGE"' "$T/log/worker" && ok \
  || bad "D2 no done result: $(grep result "$T/log/worker")"

# ── D3: the per-head guard fp on both calls, the retry under ~noverdict ──
# TEST-CHANGE (BH-6090): the retry answer carries a Findings block, since a bare
# `VERDICT: MERGE` is now unreadable by design (lr_has_findings). The fp
# assertions below do not change.
reset1; : > "$T/answer.1"; printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer.2"; tick1
[ "$(agents)" = 2 ] && ok || bad "D3 agent called $(agents) time(s), want 2"
L1=$(sed -n 1p "$T/log/agent-fp" 2>/dev/null); L2=$(sed -n 2p "$T/log/agent-fp" 2>/dev/null)
[ "$L1" = "lead-head lead:o/r#7@$SHA" ] && ok || bad "D3 first call stage/fp: '$L1'"
[ "$L2" = "lead-head lead:o/r#7@$SHA~noverdict" ] && ok || bad "D3 retry stage/fp: '$L2'"
grep -q '"verdict":"MERGE"' "$T/log/worker" && ok || bad "D3 the retry's MERGE was not posted"

# ═══════════ dispatcher section (BH-5874): the rebound replay on the worklist ═══════════
T="$T/disp"; mkdir -p "$T"
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
lwf_main_merge
djobs() { lwf_cnt '^POST /api/jobs .*"ticket_id":"lr-201-' "$T/log/worker"; }
vposts() { grep '^POST /api/verdicts ' "$T/log/worker" 2>/dev/null | sed 's/^POST \/api\/verdicts //'; }
nvposts() { local n; n=$(vposts | grep -c .); echo "${n:-0}"; }
# bset <lead word on G> — #201 on H1, rebound, token on the box
bset() {
  lwf_reset; scratch_rm "$H/state/lead-review-enqueue"
  lwf_needs_at example-org/demo-os "$H1" 201; echo "$H1" > "$FX/head.201"
  lwf_bv 201 APPROVE "$SHA" "reapproved@$H1"
  printf 'tok-fixture-lead\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"
  jq -nc --arg g "$SHA" --arg w "$1" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:$w, note:""}], truncated:false}' > "$FX/verdicts.json"
}

# ── B1: a rebound head carries the lead's MERGE ──
bset MERGE
lwf_tick
[ "$(nvposts)" = 1 ] && [ "$(vposts | jq -r '.verdict + " " + .head_sha')" = "MERGE $H1" ] && ok || bad "B1 posts: $(vposts) / $(cat "$L")"
[ "$(djobs)" = 0 ] && ok || bad "B1 lead_review jobs=$(djobs) (want 0)"
[ "$(lwf_cnt 'commits/.*/check-runs' "$T/log/gh")" = 0 ] && ok || bad "B1 a rebound head read check runs"

# ── B2: a rebound head carries the lead's BLOCK, never a MERGE ──
bset BLOCK
lwf_tick
[ "$(nvposts)" = 1 ] && ok || bad "B2 posts=$(nvposts) (want 1): $(cat "$L")"
[ "$(vposts | jq -r .verdict)" = BLOCK ] && ok || bad "B2 the replayed word: $(vposts)"
vposts | jq -e 'select(.verdict == "MERGE")' >/dev/null 2>&1 && bad "B2 a MERGE was posted after a lead BLOCK" || ok
[ "$(djobs)" = 0 ] && ok || bad "B2 lead_review jobs=$(djobs) (want 0)"

# ── B3: already replayed onto H1 ──
bset MERGE
jq --arg h "$H1" '.rows += [{id:8, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$h, verdict:"MERGE", note:"lead-replay:aaaaaaaaaaaa how:main-merge"}]' \
  "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
lwf_tick
[ "$(nvposts)" = 0 ] && ok || bad "B3 posts=$(nvposts) (want 0)"
[ "$(djobs)" = 0 ] && ok || bad "B3 lead_review jobs=$(djobs) (want 0)"
grep -q "example-org/demo-os#201 @${H1:0:12}: lead word already replayed onto this head; no post, no review" "$L" && ok || bad "B3 no line: $(cat "$L")"

# ── B4 (BH-8476): a retracted lead BLOCK on G is absent: no replay, a full review ──
bset BLOCK
jq '.rows |= map(.retracted_at = "2026-10-26T01:00:00Z" | .retract_reason = "empty-report")' \
  "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
lwf_tick
[ "$(nvposts)" = 0 ] && ok || bad "B4 a retracted BLOCK was replayed: $(vposts)"
[ "$(djobs)" = 1 ] && ok || bad "B4 lead_review jobs=$(djobs) (want 1): $(cat "$L")"

echo "lead-review-dedupe.bh-3930: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

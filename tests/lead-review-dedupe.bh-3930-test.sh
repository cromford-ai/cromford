#!/bin/bash
# tests/lead-review-dedupe.bh-3930-test.sh — BH-3941 (BH-3930.4): a PR head buys
# ONE lead review. Two production entry points, each run WHOLE (`tick`) against
# a scratch harness carrying the real jobs client and the real libs they source,
# "$DIR/bin/lib/review-bought.sh" and "$DIR/bin/lib/patch-same.sh" included:
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
#   bin/lead-review-enqueue.sh tick (D4-D6), on a reapproved@HEAD approval
#     D4  the previous head's lead MERGE, HEAD = that head + a clean main merge
#         (real git): bin/lead-verdict.sh post replays it, no POST
#         /api/lead-reviews, replayed=1. D4b: post rc 5 (advice) still replays.
#     D5  HEAD changed the patch: no post, the request is POSTed, replayed=0.
#     D6  the verdicts read answers 500, or non-JSON: today's request path.
#         D6b: post rc 1: today's request path. D6c: a truncated read, a
#         box-only history, an empty lead word: today's request path.
#     D7  HEAD already carries a source=lead lead-replay: row and nothing
#         stands (advice): no second post, no request, replayed=1.
# Stubbed: curl (the jobs worker), gh (REST reads), bin/agent-call.sh,
# bin/lead-verdict.sh and bin/lane-alert.sh (argv recorders).
# Dispatcher section (BH-5874): gate 3's BH-3930 rebound replay,
# bin/lib/lead-gates.d/50-replay-delta.sh, on the worklist. bin/lead-review.sh
# tick runs WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh, with the real
# bin/lead-verdict.sh and the lead token on the box. G is the PR commit, H1 = G
# + a main merge (#201); the builder APPROVE is on G and head-bound
# reapproved@H1.
#   B1  the lead MERGEd G: one POST /api/verdicts, MERGE on H1, and no job.
#   B2  the lead BLOCKed G: one POST /api/verdicts with BLOCK, never MERGE.
#   B3  a lead row with a lead-replay: note is already on H1: no post, no job.
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
for f in bin/lead-review.sh bin/lead-review-enqueue.sh bin/lib/review-bought.sh bin/lib/patch-same.sh; do
  [ -f "$DIR/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# ═════════════════════════ part 1: bin/lead-review.sh ═════════════════════════
H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/lead-review.sh" "$H/bin/"
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

# ═══════════════════════ part 2: bin/lead-review-enqueue.sh ═══════════════════
Q="$T/hq"; mkdir -p "$Q/bin/lib/jobs" "$Q/state" "$Q/logs" "$T/cfg" "$T/qrepos"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/lead-review-enqueue.sh" "$Q/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$Q/bin/lib/jobs/"
for f in env-path lane-gate hub-box lead-reviews verdicts gh-rest gh-pr-list gh-budget patch-same; do
  cp "$DIR/bin/lib/$f.sh" "$Q/bin/lib/"
done
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$Q/fleet.conf"

# The hub's clone of the repo. PH is the head the lead reviewed; main moved on;
# HEAD is either PH + a clean main merge (D4) or PH + a real change (D5).
QO="$T/qorigin/demo-os.git"; QW="$T/qwork"
git init -q --bare -b main "$QO"; git init -q -b main "$QW"
printf 'line 1\nline 2\nline 3\n' > "$QW/f.txt"; printf 'other\n' > "$QW/o.txt"
git -C "$QW" add -A; git -C "$QW" commit -qm base
git -C "$QW" checkout -qb pr; echo 'pr line' >> "$QW/f.txt"; git -C "$QW" commit -qam "the pr"
PH=$(git -C "$QW" rev-parse HEAD)
git -C "$QW" checkout -q main; echo 'main moved' >> "$QW/o.txt"; git -C "$QW" commit -qam "main moves"
git -C "$QW" checkout -q pr; git -C "$QW" merge -q --no-edit main; HM=$(git -C "$QW" rev-parse HEAD)
git -C "$QW" checkout -qb pr2 "$PH"; echo 'a real change' >> "$QW/f.txt"; git -C "$QW" commit -qam "changed"
HC=$(git -C "$QW" rev-parse HEAD)
git -C "$QW" push -q "$QO" main pr pr2
git clone -q "$QO" "$T/qrepos/demo-os"
PH12=${PH:0:12}

cat > "$T/fakebin/qcurl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/qworker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*standing_only=1*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  "GET /api/verdicts?"*)
    if [ -e "$T/vd500" ]; then code=500; out='{"error":"boom"}'
    elif [ -e "$T/vdjunk" ]; then out='<html>not json</html>'
    else out=\$(cat "$T/vrows.json"); fi ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/qgh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$(cat "$T/qhead")" '[{number:41, html_url:"https://github.com/example-org/demo-os/pull/41", title:"t", draft:false, state:"open",
      user:{login:"operator",type:"User"}, head:{sha:\$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' ;;
  *"-X GET repos/example-org/demo-os/pulls/41"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/qhead")" '{head:{sha:\$s},base:{ref:"main"}}' ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}]}\n' ;;
esac
exit 0
EOF
cat > "$Q/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/post"
exit "\$(cat "$T/postrc" 2>/dev/null || echo 0)"
EOF
cat > "$Q/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/qalerts"
exit 0
EOF
mkdir -p "$T/qbin"; cp "$T/fakebin/qcurl" "$T/qbin/curl"; cp "$T/fakebin/qgh" "$T/qbin/gh"
chmod +x "$T/qbin/curl" "$T/qbin/gh" "$Q/bin/lead-verdict.sh" "$Q/bin/lane-alert.sh"

QLOG="$Q/logs/lead-review-enqueue.log"
reset2() { # reset2 <head>
  rm -f "$T/log"/q* "$T/log/post" "$T"/{vd500,vdjunk,postrc} "$QLOG"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  scratch_rm "$T/jv"; mkdir -p "$T/jv"
  echo "$1" > "$T/qhead"
  # the builder's approval was on PH, rebound to the live head
  jq -nc --arg s "$PH" --arg hb "reapproved@$1" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:$hb, reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  # the verdict history: a box APPROVE and the lead MERGE, both on PH
  jq -nc --arg ph "$PH" '{rows:[{id:4,repo:"example-org/demo-os",pr:41,head_sha:$ph,source:"box",verdict:"APPROVE",note:""},
    {id:5,repo:"example-org/demo-os",pr:41,head_sha:$ph,source:"lead",verdict:"MERGE",note:"lead-review:lr-3"}],truncated:false}' > "$T/vrows.json"
}
tick2() {
  ( cd "$T" && PATH="$T/qbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 \
      bash "$Q/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?
}
qposts() { grep -c '^POST /api/lead-reviews ' "$T/log/qworker" 2>/dev/null || true; }
summ() { grep ' tick repos=' "$QLOG" 2>/dev/null | tail -1; }
hasw() { summ | grep -qw -- "$1"; }
postn() { [ -f "$T/log/post" ] && wc -l < "$T/log/post" | tr -d ' ' || echo 0; }

# ── D4: a carried-over approval on an unchanged patch replays the lead MERGE ──
reset2 "$HM"; tick2
[ "$RC" -eq 0 ] && ok || bad "D4 rc=$RC out=$(cat "$T/out")"
# TEST-CHANGE (BH-6967): the replay post also names the replayed row's review
# mode; that row has none, so it was a full review.
WANT="post example-org/demo-os 41 $HM MERGE --source lead --reviewer box:box-hub --note lead-replay:$PH12 how:main-merge --review-mode full"
[ "$(cat "$T/log/post" 2>/dev/null)" = "$WANT" ] && ok || bad "D4 lead-verdict argv: '$(cat "$T/log/post" 2>/dev/null)' want '$WANT'"
[ "$(qposts)" = 0 ] && ok || bad "D4 a lead review was requested on an unchanged patch: $(grep 'POST /api/lead-reviews' "$T/log/qworker")"
hasw replayed=1 && hasw requested=0 && ok || bad "D4 summary: $(summ)"
grep -q "example-org/demo-os#41 @${HM:0:12}: lead MERGE replayed from $PH12 (how:main-merge, post rc 0); no review requested" "$QLOG" \
  && ok || bad "D4 no replay log line: $(cat "$QLOG")"
# D4b: the post records the row as advice (rc 5): still replayed, still no request
reset2 "$HM"; echo 5 > "$T/postrc"; tick2
[ "$(postn)" = 1 ] && [ "$(qposts)" = 0 ] && hasw replayed=1 && ok || bad "D4b rc 5: posts=$(postn) requests=$(qposts) $(summ)"

# ── D5: the patch changed: no replay, today's request ──
reset2 "$HC"; tick2
[ "$(postn)" = 0 ] && ok || bad "D5 a changed patch was replayed: $(cat "$T/log/post")"
[ "$(qposts)" = 1 ] && ok || bad "D5 want one POST /api/lead-reviews, got $(qposts)"
hasw replayed=0 && hasw requested=1 && ok || bad "D5 summary: $(summ)"

# ── D6: an unreadable verdicts read is never a replay and never a skip ──
reset2 "$HM"; : > "$T/vd500"; tick2
[ "$(postn)" = 0 ] && [ "$(qposts)" = 1 ] && hasw replayed=0 && hasw requested=1 && ok \
  || bad "D6 a 500 verdicts read: posts=$(postn) requests=$(qposts) $(summ)"
grep -q 'verdicts read failed; requesting as before' "$QLOG" && ok || bad "D6 no read-failed line: $(cat "$QLOG")"
reset2 "$HM"; : > "$T/vdjunk"; tick2
[ "$(postn)" = 0 ] && [ "$(qposts)" = 1 ] && hasw replayed=0 && hasw requested=1 && ok \
  || bad "D6 a non-JSON verdicts read: posts=$(postn) requests=$(qposts) $(summ)"
# D6b: the post itself refused (rc 1): today's request
reset2 "$HM"; echo 1 > "$T/postrc"; tick2
[ "$(postn)" = 1 ] && [ "$(qposts)" = 1 ] && hasw replayed=0 && hasw requested=1 && ok \
  || bad "D6b post rc 1: posts=$(postn) requests=$(qposts) $(summ)"

# D6c: what never replays: a truncated history, only a box row on PH, a lead
# row with no word. Each takes today's request path.
reset2 "$HM"; jq -c '.truncated = true' "$T/vrows.json" > "$T/v2" && mv "$T/v2" "$T/vrows.json"; tick2
[ "$(postn)" = 0 ] && [ "$(qposts)" = 1 ] && hasw replayed=0 && ok || bad "D6c a truncated read replayed: posts=$(postn) requests=$(qposts) $(summ)"
grep -q 'verdicts read failed; requesting as before' "$QLOG" && ok || bad "D6c a truncated read was not named unreadable: $(cat "$QLOG")"
reset2 "$HM"; jq -c '.rows |= map(select(.source != "lead"))' "$T/vrows.json" > "$T/v2" && mv "$T/v2" "$T/vrows.json"; tick2
[ "$(postn)" = 0 ] && [ "$(qposts)" = 1 ] && hasw replayed=0 && ok || bad "D6c a box-only history replayed: posts=$(postn) requests=$(qposts) $(summ)"
reset2 "$HM"; jq -c '.rows |= map(if .source == "lead" then .verdict = "" else . end)' "$T/vrows.json" > "$T/v2" && mv "$T/v2" "$T/vrows.json"; tick2
[ "$(postn)" = 0 ] && [ "$(qposts)" = 1 ] && hasw replayed=0 && ok || bad "D6c an empty lead word replayed: posts=$(postn) requests=$(qposts) $(summ)"

# ── D7: a head already replayed onto is not posted again (rc 5 advice does not stand) ──
reset2 "$HM"
jq -c --arg h "$HM" --arg n "lead-replay:$PH12 how:main-merge" \
  '.rows += [{id:6,repo:"example-org/demo-os",pr:41,head_sha:$h,source:"lead",verdict:"MERGE",note:$n}]' "$T/vrows.json" > "$T/v2" && mv "$T/v2" "$T/vrows.json"
tick2
[ "$RC" -eq 0 ] && ok || bad "D7 rc=$RC out=$(cat "$T/out")"
[ "$(postn)" = 0 ] && ok || bad "D7 a replayed head was posted again: $(cat "$T/log/post")"
[ "$(qposts)" = 0 ] && ok || bad "D7 a replayed head was requested: $(qposts)"
hasw replayed=1 && hasw requested=0 && ok || bad "D7 summary: $(summ)"
grep -q "example-org/demo-os#41 @${HM:0:12}: lead word already replayed onto this head" "$QLOG" && ok || bad "D7 no already-replayed line: $(cat "$QLOG")"
# a lead-replay: note on ANOTHER head does not count for this one
reset2 "$HM"
jq -c --arg n "lead-replay:$PH12 how:main-merge" \
  '.rows += [{id:6,repo:"example-org/demo-os",pr:41,head_sha:"'"$HC"'",source:"lead",verdict:"MERGE",note:$n}]' "$T/vrows.json" > "$T/v2" && mv "$T/v2" "$T/vrows.json"
tick2
grep -q 'already replayed' "$QLOG" && bad "D7 a replay on another head blocked this one: $(cat "$QLOG")" || ok

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

echo "lead-review-dedupe.bh-3930: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/lead-review-concurrent.bh-5317-test.sh — BH-5317: the lead-review tick
# lock (fd 7, locks/lead-review-tick.lock) is a dedupe that owes ONE rerun, is
# never pinned by repo code the tick ran, and the chain's crons are */15
# backstops. The REAL bin/lead-review.sh tick against scratch harnesses
# carrying its real bin/lib closure ("$DIR/bin/lib/lead-chain-wake.sh" and
# "$DIR/bin/lib/review-pool.sh" included). Stubbed: curl (the jobs worker), gh,
# df and /proc/meminfo, bin/agent-call.sh, bin/rules-pack.sh.
#   C1  the lock held elsewhere: rc 0 at once, no worker request, no agent
#       call, state/lead-review/rerun-owed written, `tick skipped ... (rerun owed)`.
#   C4  marker + LEAD_REVIEW_RERUN_MAX=3 + a stored report: replayed with no
#       agent call, `rerun owed (depth 1/3)`, marker gone, the detached rerun
#       writes a second summary, zero agent calls, one `rerun owed (depth` line.
#   C5  depth 3 of 3: `depth 3/3 reached`, one summary, marker removed. Knob 0:
#       `rerun owed but off`, one summary, marker kept.
#   C5b the LEAD_REVIEW_RERUN_MAX registry tuple, and lane_env_apply exports 3.
#   C6  a host suite leaves a process behind; the agent SIGKILLs its worker and
#       the tick: the next tick is not skipped and writes a summary.
#   C6c the same with the rules pack (fleet.conf cromford) leaving one.
#   C6b the agent leaves a process behind holding fd 7 and tick 1 ends
#       normally: tick 2 is not skipped (the end-of-tick flock -u 7).
#   C7  lines 2-4 of bin/lead-review.sh name `15 minutes` and the `doorbell`.
#   C8  710/715 each run once at */15; 713 (the enqueue) is deleted
#       (BH-8363); 410-* and 714-* match origin/main.
#   C9  K=1, two requests, a slow agent and LEAD_REVIEW_DEADLINE_S=4 (BH-4956:
#       the per-tick start cap is gone, so the deadline defers the second), no
#       marker: deferred=1 forces `rerun owed (depth 1/3)` and the rerun
#       reviews the second. Over the spend cap (closed_by=spend): no rerun.
# LR_BASE_SCRIPT=<path> runs the lead-review cases against another
# bin/lead-review.sh (the red check against main's).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-concurrent.bh-5317-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
command -v setsid >/dev/null || { echo "FAIL: setsid missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

H="$T/h"
mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$H/flags" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp" "$T/jobs"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install of $s"; exit 1; }
done
[ -r "$H/bin/lib/review-pool.sh" ] && [ -r "$H/bin/lib/lead-chain-wake.sh" ] \
  || { echo "FAIL: the closure did not install review-pool.sh and lead-chain-wake.sh"; exit 1; }
if [ -n "${LR_BASE_SCRIPT:-}" ]; then cp "$LR_BASE_SCRIPT" "$H/bin/lead-review.sh"; chmod +x "$H/bin/lead-review.sh"; fi
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"

# origin: the PR commit declares a Verification Contract that leaves a process
# behind when $T/leave.suite exists, and records its pid in $T/left.
O="$T/origin/r.git"; W="$T/work/r"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
cat > "$W/CLAUDE.md" <<EOF
# demo

## Verification Contract

\`\`\`bash
if [ -e "$T/leave.suite" ]; then sleep 30 & echo \$! >> "$T/left"; fi; true
\`\`\`
EOF
echo two >> "$W/a.txt"; git -C "$W" add -A; git -C "$W" commit -qm "pr change"
SHA=$(git -C "$W" rev-parse HEAD); SHA12=${SHA:0:12}
for n in 7 8; do git -C "$W" push -q "$O" "HEAD:refs/pull/$n/head"; done
git clone -q "$O" "$T/repos/demo-os"; git clone -q "$O" "$T/repos/cromford"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
body=\$(printf '%s' "\$body" | tr -d '\n')
p="\${url#https://jobs.test}"
( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(jq -c '{requests:., truncated:false}' "$T/rows.json") ;;
  "POST /api/jobs")
    k=\$(printf '%s' "\$body" | jq -r '.ticket_id')
    if mkdir "$T/jobs/\$k" 2>/dev/null; then out=\$(jq -nc --arg k "\$k" '{job:{id:("job-" + \$k)}}')
    else code=409; out='{"job":{"id":"job-x","box":"box-other"}}'; fi ;;
  "POST /api/wakes/lane") out='{"inserted":1}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
  "GET /api/metrics/llm-spend"*) out=\$(cat "$T/spend.json" 2>/dev/null || echo '{"usd":0}') ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/gh"
a="\$*"
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls\ .*page=([0-9]+) ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  if [ "\${BASH_REMATCH[1]}" = 1 ]; then jq -nc --arg s "$SHA" '[7, 8 | {number:., head:{sha:\$s}, labels:[]}]'; else echo '[]'; fi
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls/([0-9]+) ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg s "$SHA" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}'
  exit 0
fi
exit 0
EOF
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 %s 1%% /tmp\n' "\$((102400 * 1024))"
EOF
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/meminfo"
# The agent. $T/killmode: SIGKILL the worker ($PPID) and the tick (its parent),
# having closed its own fd 7 first: it stands for an agent call that ended, so
# only what the tick left behind could still hold the lock. $T/leave.agent:
# leave a process behind that keeps the inherited fd 7, and answer normally.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
if [ -e "$T/killmode" ]; then
  exec 7>&-
  tk=\$(ps -o ppid= -p "\$PPID" | tr -d ' ')
  kill -9 "\$PPID" "\$tk" 2>/dev/null
  exit 0
fi
if [ -e "$T/leave.agent" ]; then sleep 30 >/dev/null 2>&1 & echo \$! >> "$T/left"; fi
[ -e "$T/agent.sleep" ] && sleep "\$(cat "$T/agent.sleep")"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/df" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S LEAD_REVIEW_MAX_PAGES PR_SNAPSHOT HOTFIX_LABEL HOTFIX_LANE
unset LEAD_REVIEW_CONCURRENCY LEAD_REVIEW_BOX_MAX LEAD_REVIEW_TMP_MIN_MB LLM_USD_CAP_DAY REVIEW_POOL_TMP_PATH
unset LEAD_CHAIN_RERUN_DEPTH AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_RERUN_MAX

L="$H/logs/lead-review.log"
LOCK="$H/locks/lead-review-tick.lock"
MARK="$H/state/lead-review/rerun-owed"
rows() { # rows <pr>... -> $T/rows.json
  local n i=0 out='[]'
  for n in "$@"; do
    out=$(jq -c --arg n "$n" --arg s "$SHA" --argjson i "$i" \
      '. + [{id:("r-" + $n), repo:"o/r", pr:($n|tonumber), head_sha:$s, status:"requested",
             created_at:("2026-10-07 05:00:0" + ($i|tostring)), scope_notes:null}]' <<<"$out")
    i=$((i + 1))
  done
  printf '%s\n' "$out" > "$T/rows.json"
}
# kill_left — end every process a case left behind (pids in $T/left)
kill_left() { local p; [ -f "$T/left" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$T/left"; rm -f "$T/left"; }
# settle — no tick (nor a detached rerun) still holds the lock
settle() { mkdir -p "$H/locks"; flock -w 30 "$LOCK" true || echo "settle: the lock is still held after 30s"; }
reset() {
  kill_left; settle
  rm -f "$T/log"/* "$T"/{killmode,leave.suite,leave.agent,spend.json,agent.sleep} "$L" "$MARK" "$H/bin/rules-pack.sh"
  scratch_rm "$T/jobs"; mkdir -p "$T/jobs"; scratch_rm "$H/state/lead-reviews"; rm -f "$H/state"/review-pool-*
  printf 'demo-os o/r https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"
  rows 7
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
# ktick — a tick the agent stub SIGKILLs (the outer subshell eats the shell's "Killed" notice)
ktick() { { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; } 2>/dev/null; }
summaries() { local n; n=$(grep -c ' tick seen=' "$L" 2>/dev/null); echo "${n:-0}"; }
# wait_summaries <n> — bounded wait for the n-th summary line (a detached rerun's)
wait_summaries() { local i; for i in $(seq 1 300); do [ "$(summaries)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
logtxt() { cat "$L" 2>/dev/null; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

# ── C1: the lock is held: skip at once, owe a rerun ──
reset; mkdir -p "$H/locks"
( exec 8>"$LOCK"; flock -n 8 || exit 1; : > "$T/held"; exec sleep 30 ) & HOLD=$!
for i in $(seq 1 100); do [ -e "$T/held" ] && break; sleep 0.05; done
S0=$SECONDS; tick; S1=$SECONDS
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; rm -f "$T/held"
[ "$RC" -eq 0 ] && ok || bad "C1 rc=$RC $(cat "$T/out")"
[ $((S1 - S0)) -lt 5 ] && ok || bad "C1 the tick took $((S1 - S0))s"
[ -s "$T/log/worker" ] && bad "C1 a worker request: $(cat "$T/log/worker")" || ok
[ "$(agents)" = 0 ] && ok || bad "C1 agent calls=$(agents)"
[ -e "$MARK" ] && ok || bad "C1 state/lead-review/rerun-owed not written"
grep -q 'tick skipped: the previous tick still holds locks/lead-review-tick.lock.*(rerun owed)' "$L" && ok || bad "C1 no skip line: $(logtxt)"

# ── C4: the owed rerun over a stored report: no agent call anywhere ──
reset; mkdir -p "$H/state/lead-review" "$H/state/lead-reviews"; : > "$MARK"
printf '# Lead review lr-7-%s (o/r#7 at %s)\n\n- verdict: MERGE\n- host suite: no host suite declared\n- rules pack: not installed on this box\n- reviewer model: stub-model\n\nVERDICT: MERGE\n' \
  "$SHA12" "$SHA" > "$H/state/lead-reviews/lr-7-$SHA12.md"
LEAD_REVIEW_RERUN_MAX=3 tick
[ "$RC" -eq 0 ] && ok || bad "C4 rc=$RC $(cat "$T/out")"
grep -q "reusing .* for lr-7-$SHA12; no agent call" "$L" && ok || bad "C4 no replay line: $(logtxt)"
grep -q 'rerun owed (depth 1/3)' "$L" && ok || bad "C4 no rerun line: $(logtxt)"
[ -e "$MARK" ] && bad "C4 the marker survived the rerun launch" || ok
wait_summaries 2 && ok || bad "C4 the detached rerun wrote no summary: $(logtxt)"
settle
[ "$(agents)" = 0 ] && ok || bad "C4 agent calls=$(agents)"
[ "$(cnt 'rerun owed (depth' "$L")" = 1 ] && ok || bad "C4 rerun lines=$(cnt 'rerun owed (depth' "$L") (want 1): $(logtxt)"

# ── C5: the depth bound, and the knob off ──
reset; echo '[]' > "$T/rows.json"; mkdir -p "$H/state/lead-review"; : > "$MARK"
LEAD_CHAIN_RERUN_DEPTH=3 LEAD_REVIEW_RERUN_MAX=3 tick
grep -q 'rerun owed but depth 3/3 reached' "$L" && ok || bad "C5 no depth line: $(logtxt)"
[ "$(summaries)" = 1 ] && ok || bad "C5 summaries=$(summaries)"
[ -e "$MARK" ] && bad "C5 the marker survived the depth bound" || ok
reset; echo '[]' > "$T/rows.json"; mkdir -p "$H/state/lead-review"; : > "$MARK"
LEAD_REVIEW_RERUN_MAX=0 tick
grep -q "rerun owed but off (max='0')" "$L" && ok || bad "C5 knob 0: no off line: $(logtxt)"
[ "$(summaries)" = 1 ] && ok || bad "C5 knob 0: summaries=$(summaries)"
[ -e "$MARK" ] && ok || bad "C5 knob 0 dropped the marker"

# ── C5b: the registry knob, and what lane_env_apply exports ──
LRJ="$DIR/catalog/lanes.d/lead-review.json"
G=$(jq -c '.knobs[]? | select(.env=="LEAD_REVIEW_RERUN_MAX") | [.type,.default,.min,.max,.zero_means,.required]' "$LRJ" 2>/dev/null)
[ "$G" = '["int",3,0,20,"off",true]' ] && ok || bad "C5b LEAD_REVIEW_RERUN_MAX is '$G'"
HK="$T/hk"; mkdir -p "$HK/bin/lib" "$HK/state" "$HK/logs" "$HK/catalog"
scratch_install_closure bin/lib/lane-gate.sh "$HK" >/dev/null || { echo "FAIL: closure install of bin/lib/lane-gate.sh"; exit 1; }
cp "$(rendered_registry)" "$HK/catalog/lanes.json"
printf '_jobs_req() { printf %%s %q; }\n' '{"settings":[]}' > "$HK/bin/stub-jobs-client.sh"
V=$(env -u LEAD_REVIEW_RERUN_MAX -u LANE_GATE_DISABLE HARNESS="$HK" LANE_GATE_NOW=1758300000 bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply lead-review
  printf "%s" "${LEAD_REVIEW_RERUN_MAX:-UNSET}"' 2>/dev/null)
[ "$V" = 3 ] && ok || bad "C5b lane_env_apply lead-review exported '$V' (want 3)"

# ── C6: a host suite leaves a process behind; the worker and tick die ──
reset; : > "$T/leave.suite"; : > "$T/killmode"
ktick
[ "$(agents)" = 1 ] && ok || bad "C6 the agent stub was not reached: $(logtxt)"
[ -s "$T/left" ] && ok || bad "C6 the host suite left nothing behind (the case proves nothing)"
[ "$(summaries)" = 0 ] && ok || bad "C6 tick 1 was not killed: $(logtxt)"
rm -f "$T/killmode"
tick
[ "$(summaries)" = 1 ] && ok || bad "C6 tick 2 wrote no summary: $(logtxt)"
grep -q 'tick skipped' "$L" && bad "C6 tick 2 was skipped: a process the host suite left holds the lock" || ok

# ── C6c: the rules pack leaves a process behind ──
reset; : > "$T/killmode"
printf 'cromford o/r https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"
printf '#!/bin/bash\nsleep 30 >/dev/null 2>&1 &\necho $! >> "%s/left"\nexit 0\n' "$T" > "$H/bin/rules-pack.sh"; chmod +x "$H/bin/rules-pack.sh"
ktick
[ "$(agents)" = 1 ] && ok || bad "C6c the agent stub was not reached: $(logtxt)"
[ -s "$T/left" ] && ok || bad "C6c the rules pack left nothing behind"
rm -f "$T/killmode"
tick
[ "$(summaries)" = 1 ] && ok || bad "C6c tick 2 wrote no summary: $(logtxt)"
grep -q 'tick skipped' "$L" && bad "C6c tick 2 was skipped: a process the rules pack left holds the lock" || ok

# ── C6b: the agent leaves a process behind; tick 1 ends normally ──
reset; : > "$T/leave.agent"
tick
[ "$(summaries)" = 1 ] && ok || bad "C6b tick 1 wrote no summary: $(logtxt)"
[ -s "$T/left" ] && ok || bad "C6b the agent left nothing behind"
tick
[ "$(summaries)" = 2 ] && ok || bad "C6b tick 2 wrote no summary: $(logtxt)"
grep -q 'tick skipped' "$L" && bad "C6b tick 2 was skipped: the agent's leftover pinned the lock after tick 1 ended" || ok

# ── C7: the header names the backstop and the doorbell ──
HDR=$(sed -n 2,4p "$H/bin/lead-review.sh")
[[ "$HDR" == *"15 minutes"* && "$HDR" == *doorbell* ]] && ok || bad "C7 lines 2-4: $HDR"

# ── C8: the two stage crons are */15 backstops; the neighbours are untouched ──
# TEST-CHANGE BH-8363: 713-lead-review-enqueue.cron is deleted with the lane
# JSON, so it is checked for absence, not for a stub with zero schedule lines.
for f in 710-lead-review 715-lead-review-land; do
  CL=$(grep -v '^[[:space:]]*#' "$DIR/cron/lanes/$f.cron" | grep -c '[^[:space:]]')
  C15=$(grep -c '^\*/15 ' "$DIR/cron/lanes/$f.cron")
  [ "$CL" = 1 ] && [ "$C15" = 1 ] && ok || bad "C8 $f.cron: $CL command lines, $C15 at */15"
done
[ ! -e "$DIR/cron/lanes/713-lead-review-enqueue.cron" ] && ok || bad "C8 cron/lanes/713-lead-review-enqueue.cron exists, want it deleted"
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  for f in "$DIR"/cron/lanes/410-*.cron "$DIR"/cron/lanes/714-*.cron; do
    rel="cron/lanes/${f##*/}"
    [ "$(git -C "$DIR" show "origin/main:$rel" 2>/dev/null)" = "$(cat "$f")" ] && ok || bad "C8 $rel differs from origin/main"
  done
else
  echo "C8 note: no origin/main here; the 410/714 comparison is skipped"
fi

# ── C9: deferred work forces one rerun; a spend refusal does not ──
reset; rows 7 8; echo 7 > "$T/agent.sleep"
LEAD_REVIEW_RERUN_MAX=3 LEAD_REVIEW_CONCURRENCY=1 LEAD_REVIEW_DEADLINE_S=4 tick
S=$(grep ' tick seen=' "$L" | head -1)
[[ "$S" == *" deferred=1 "* ]] && ok || bad "C9 summary: $S"
grep -q 'rerun owed (depth 1/3)' "$L" && ok || bad "C9 no forced rerun: $(logtxt)"
wait_summaries 2 && ok || bad "C9 the rerun wrote no summary: $(logtxt)"
settle
[ "$(cnt '^.* done lr-' "$L")" = 2 ] && ok || bad "C9 done reviews=$(cnt '^.* done lr-' "$L") (want 2: the rerun took the second)"
grep -q "done lr-8-$SHA12" "$L" && ok || bad "C9 the second request was not reviewed: $(logtxt)"
reset; rows 7 8; echo '{"usd":12.5}' > "$T/spend.json"
LLM_USD_CAP_DAY=5 LEAD_REVIEW_RERUN_MAX=3 LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=1 tick
grep -q 'spend cap reached' "$L" && ok || bad "C9 spend: no cap line: $(logtxt)"
grep -q 'rerun owed' "$L" && bad "C9 spend: a rerun was launched into the cap: $(logtxt)" || ok

kill_left
echo "lead-review-concurrent.bh-5317: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/lead-review-tick-lock.bh-6984-test.sh — BH-6984: the lead-review tick
# releases locks/lead-review-tick.lock (fd 7) when its starts close, BEFORE it
# waits for its running reviews. A later tick then counts the box's running
# workers (state/lead-review/pool, one file a live worker) against the slot cap
# and starts more. The REAL bin/lead-review.sh tick against a scratch harness
# with its real bin/lib closure (review-pool.sh, lead-chain-wake.sh). Stubbed:
# curl (the jobs worker; POST /api/jobs is the DB claim: a second open of one
# key answers 409), gh, df, /proc/meminfo, bin/agent-call.sh (it sleeps).
#   L1  tick A starts #7 (a slow review); tick B, started while #7 runs, starts
#       #8 (box cap 7): two agent calls overlap, B writes a summary (seen=2
#       done=1 skipped=1), and no line says the previous tick still holds the lock.
#   L2  box cap 1 (LEAD_REVIEW_BOX_MAX=1) and A's review running: tick B starts
#       nothing (one agent call in all), exits 0, and writes its summary
#       (started=0), never `tick skipped`.
#   L3  A and B list the same request #7: B reaches the claim and is refused
#       by the DB claim (job_open 409 = `skip lr-7-...`); one /claim post and
#       one agent call for r-7 in all.
#   L4  tick A gets SIGTERM while its review runs: the worker keeps its TMPDIR,
#       finishes, and posts its result (a tick that ends early never takes
#       its workers' scratch).
#   L5  review-pool alone: one live and one gone worker file of other ticks:
#       rpool_others=1 (the gone one removed), rpool_box_running=1, and the
#       memory term of K adds the live one back (2048MB / 700MB + 1 = 3).
# LR_BASE_SCRIPT=<path> runs the cases against another bin/lead-review.sh
# (the red check against main's).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-tick-lock.bh-6984-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

H="$T/h"
mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$H/flags" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp" "$T/jobs" "$T/running"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install of $s"; exit 1; }
done
[ -r "$H/bin/lib/review-pool.sh" ] || { echo "FAIL: the closure did not install review-pool.sh"; exit 1; }
if [ -n "${LR_BASE_SCRIPT:-}" ]; then cp "$LR_BASE_SCRIPT" "$H/bin/lead-review.sh"; chmod +x "$H/bin/lead-review.sh"; fi
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
printf 'demo-os o/r https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"

O="$T/origin/r.git"; W="$T/work/r"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" add -A; git -C "$W" commit -qm "pr change"
SHA=$(git -C "$W" rev-parse HEAD); SHA12=${SHA:0:12}
for n in 7 8; do git -C "$W" push -q "$O" "HEAD:refs/pull/$n/head"; done
git clone -q "$O" "$T/repos/demo-os"

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
# The agent: marks itself running in $T/running, records how many run at once
# and whether its TMPDIR (the worker's pool scratch) still exists after the
# sleep, then answers MERGE.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
pr=\${AGENT_CALL_PR##*/}
echo "\$pr" >> "$T/log/agent-count"
: > "$T/running/\$\$"
ls "$T/running" | wc -l | tr -d ' ' >> "$T/log/peak"
[ -e "$T/agent.sleep" ] && sleep "\$(cat "$T/agent.sleep")"
if [ -d "\$TMPDIR" ]; then echo kept >> "$T/log/tmpdir"; else echo gone >> "$T/log/tmpdir"; fi
rm -f "$T/running/\$\$"
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
reset() {
  rm -f "$T/log"/* "$T"/{spend.json,agent.sleep,outA,outB} "$L" "$T/running"/*
  scratch_rm "$T/jobs"; mkdir -p "$T/jobs"; scratch_rm "$H/state/lead-reviews"; rm -f "$H/state"/review-pool-*
}
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
summaries() { local n; n=$(grep -c ' tick seen=' "$L" 2>/dev/null); echo "${n:-0}"; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
logtxt() { cat "$L" 2>/dev/null; }
# wait_for <seconds> <command...> — poll until the command succeeds; rc 1 at the bound
wait_for() { local i n=$(( $1 * 20 )); shift; for i in $(seq 1 "$n"); do "$@" && return 0; sleep 0.05; done; return 1; }
agents_ge() { [ "$(agents)" -ge "$1" ]; }
# tick_a — tick A in the background (PA); it reviews the rows of the moment
tick_a() { ( cd "$T" && exec bash "$H/bin/lead-review.sh" tick ) > "$T/outA" 2>&1 & PA=$!; }
tick_b() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/outB" 2>&1; RCB=$?; }

# ── L1: a second tick starts a second review while the first one runs ──
reset; rows 7; echo 6 > "$T/agent.sleep"; export LEAD_REVIEW_BOX_MAX=7
tick_a
wait_for 30 agents_ge 1 || bad "L1 tick A never reached its agent call: $(logtxt)"
rows 7 8
tick_b
[ "$RCB" -eq 0 ] && ok || bad "L1 tick B rc=$RCB $(cat "$T/outB")"
grep -q 'still holds locks/lead-review-tick.lock' "$L" && bad "L1 tick B was skipped on the tick lock: $(logtxt)" || ok
grep -q '^8$' "$T/log/agent-count" 2>/dev/null && ok || bad "L1 tick B did not review #8 (agent calls: $(tr '\n' ' ' < "$T/log/agent-count" 2>/dev/null))"
[ "$(sort -n "$T/log/peak" 2>/dev/null | tail -1)" = 2 ] && ok || bad "L1 the two reviews never ran at once (peak $(tr '\n' ' ' < "$T/log/peak" 2>/dev/null))"
wait "$PA"; RCA=$?
grep -qE ' tick seen=2 .* done=1 .* skipped=1 ' "$L" && ok || bad "L1 no summary from tick B (seen=2 done=1 skipped=1: #8 reviewed, #7 refused): $(logtxt)"
[ "$RCA" -eq 0 ] && ok || bad "L1 tick A rc=$RCA $(cat "$T/outA")"
[ "$(summaries)" = 2 ] && ok || bad "L1 summaries=$(summaries) (want 2)"
[ "$(cnt '^.* done lr-' "$L")" = 2 ] && ok || bad "L1 done reviews=$(cnt '^.* done lr-' "$L") (want 2): $(logtxt)"

# ── L2: the box cap is reached: the second tick starts nothing, rc 0 ──
reset; rows 7; echo 6 > "$T/agent.sleep"; export LEAD_REVIEW_BOX_MAX=1
tick_a
wait_for 30 agents_ge 1 || bad "L2 tick A never reached its agent call: $(logtxt)"
rows 7 8
LEAD_REVIEW_DEADLINE_S=2 tick_b
[ "$RCB" -eq 0 ] && ok || bad "L2 tick B rc=$RCB $(cat "$T/outB")"
[ "$(agents)" = 1 ] && ok || bad "L2 agent calls=$(agents) while the cap was reached (want 1)"
grep -q 'tick skipped' "$L" && bad "L2 tick B was skipped on the tick lock, not refused by the cap: $(logtxt)" || ok
grep -qE ' tick seen=.* started=0 ' "$L" && ok || bad "L2 no summary with started=0 from tick B: $(logtxt)"
wait "$PA"
[ "$(agents)" = 1 ] && ok || bad "L2 agent calls=$(agents) after tick A (want 1)"

# ── L3: one request is never claimed by two ticks ──
reset; rows 7; echo 6 > "$T/agent.sleep"; export LEAD_REVIEW_BOX_MAX=7
tick_a
wait_for 30 agents_ge 1 || bad "L3 tick A never reached its agent call: $(logtxt)"
tick_b
wait "$PA"
grep -q "skip lr-7-$SHA12: " "$L" && ok || bad "L3 tick B never reached the claim of #7 (the DB claim refused nothing): $(logtxt)"
[ "$(cnt 'POST /api/lead-reviews/r-7/claim' "$T/log/worker")" = 1 ] && ok || bad "L3 /claim posts for r-7=$(cnt 'POST /api/lead-reviews/r-7/claim' "$T/log/worker") (want 1)"
[ "$(agents)" = 1 ] && ok || bad "L3 agent calls=$(agents) (want 1)"
[ "$(cnt '^.* done lr-7-' "$L")" = 1 ] && ok || bad "L3 done lines for #7=$(cnt '^.* done lr-7-' "$L") (want 1)"

# ── L4: SIGTERM to the tick: its running worker keeps its scratch and records ──
reset; rows 7; echo 3 > "$T/agent.sleep"; export LEAD_REVIEW_BOX_MAX=7
tick_a
wait_for 30 agents_ge 1 || bad "L4 tick A never reached its agent call: $(logtxt)"
kill -TERM "$PA"; wait "$PA" 2>/dev/null
has_result() { grep -q 'POST /api/lead-reviews/r-7/result' "$T/log/worker" 2>/dev/null; }
wait_for 30 has_result && ok || bad "L4 the worker posted no result after its tick ended: $(logtxt)"
[ "$(cat "$T/log/tmpdir" 2>/dev/null)" = kept ] && ok || bad "L4 the worker's TMPDIR was removed under it (tmpdir: $(cat "$T/log/tmpdir" 2>/dev/null))"
# ── L5: review-pool's box count, and the memory term adds the others back ──
LD="$T/live"; mkdir -p "$LD"; sleep 30 & SP=$!
echo "$SP" > "$LD/1-r0"; echo 999999 > "$LD/2-r0"
printf 'MemTotal: 4194304 kB\nMemAvailable: 2097152 kB\n' > "$T/meminfo5"
V=$(env -u LEAD_REVIEW_BOX_MAX REVIEW_POOL_MEMINFO="$T/meminfo5" REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_SWEEP= \
  LEAD_REVIEW_WORKER_MEM_MB=700 RPOOL_T="$LD" bash -c '
  . "$HARNESS/bin/lib/review-pool.sh"
  RPOOL_LIVE_DIR="$RPOOL_T"
  rpool_init lead-review LEAD_REVIEW 10 "$TMPDIR/pool5" true
  printf "%s %s %s" "$(rpool_others)" "$(rpool_box_running)" "$RPOOL_K"' 2>&1)
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
[ "$V" = "1 1 3" ] && ok || bad "L5 others/box_running/K = '$V' (want '1 1 3': 2048MB/700MB = 2, plus 1 running elsewhere)"
[ -e "$LD/2-r0" ] && bad "L5 the file of a gone pid was kept" || ok

unset LEAD_REVIEW_BOX_MAX
echo "lead-review-tick-lock.bh-6984: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

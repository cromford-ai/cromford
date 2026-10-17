#!/bin/bash
# tests/lead-review-tick-lock-measure.bh-5945-test.sh — BH-5945: the lead-review
# tick measures how long it held locks/lead-review-tick.lock (fd 7). The REAL
# bin/lead-review.sh tick against a scratch harness with its real bin/lib
# closure (the fixture of tests/lead-review-tick-lock.bh-6984-test.sh). Box cap
# 1 and two requests: tick A starts #7 and holds the lock while it waits for a
# slot for #8, so a second tick in that window finds the lock held.
#   M1  tick A writes state/lead-review/tick-lock.since when it takes the lock;
#       tick B, run while A holds it, logs `held <n>s (rerun owed)`; when A
#       ends the log has exactly one `tick lock held <n>s started=<n>` line.
#   M2  the skip still writes state/lead-review/rerun-owed and exits 0.
#   M3  no stamp file (removed while A holds the lock): the skip says `held ?s`.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-tick-lock-measure.bh-5945-test.sh
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

stamp="$H/state/lead-review/tick-lock.since"
has_stamp() { [ -s "$stamp" ]; }

# ── M1 / M2: the holder stamps, the skipped tick reads it, one held line ──
reset; rm -f "$H/state/lead-review/rerun-owed" "$stamp"; rows 7 8; echo 4 > "$T/agent.sleep"; export LEAD_REVIEW_BOX_MAX=1
tick_a
wait_for 30 agents_ge 1 || bad "M1 tick A never reached its agent call: $(logtxt)"
has_stamp && ok || bad "M1 tick A wrote no $stamp while it held the lock"
grep -qE '^[0-9]+$' "$stamp" 2>/dev/null && ok || bad "M1 the stamp is not one epoch line: $(cat "$stamp" 2>/dev/null)"
tick_b
[ "$RCB" -eq 0 ] && ok || bad "M2 tick B rc=$RCB $(cat "$T/outB")"
grep -qE 'tick skipped: the previous tick still holds locks/lead-review-tick.lock \(a review is running\) held [0-9]+s \(rerun owed\)$' "$L" \
  && ok || bad "M1 no skip line with held <n>s: $(logtxt)"
[ -e "$H/state/lead-review/rerun-owed" ] && ok || bad "M2 the skip wrote no rerun-owed marker"
wait "$PA"
[ "$(grep -cE ' tick lock held [0-9]+s started=[0-9]+$' "$L")" = 1 ] && ok || bad "M1 want one 'tick lock held' line: $(logtxt)"
grep -qE ' tick lock held [0-9]+s started=2$' "$L" && ok || bad "M1 the held line does not carry started=2: $(logtxt)"

# ── M3: the stamp is unreadable: held ?s, never a made-up number ──
reset; rm -f "$H/state/lead-review/rerun-owed" "$stamp"; rows 7 8; echo 4 > "$T/agent.sleep"; export LEAD_REVIEW_BOX_MAX=1
tick_a
wait_for 30 agents_ge 1 || bad "M3 tick A never reached its agent call: $(logtxt)"
rm -f "$stamp"
tick_b
grep -qF '(a review is running) held ?s (rerun owed)' "$L" && ok || bad "M3 no 'held ?s' skip line: $(logtxt)"
wait "$PA"

unset LEAD_REVIEW_BOX_MAX
echo "lead-review-tick-lock-measure.bh-5945: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

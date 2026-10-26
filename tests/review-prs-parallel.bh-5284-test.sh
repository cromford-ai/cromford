#!/bin/bash
# tests/review-prs-parallel.bh-5284-test.sh — BH-5284: bin/review-prs.sh reviews
# up to REVIEW_CONCURRENCY PRs at once (bin/lib/review-pool.sh). The lane runs
# WHOLE from a scratch harness carrying its real bin/lib closure (review-pool,
# review-bought, gh-pr-list, …). Stubbed: gh (behind tests/lib/gh-list-bridge.sh),
# the jobs functions (BASH_ENV, recording review rows opened and closed), df and
# /proc/meminfo, and bin/agent-call.sh, which sleeps $T/sleep seconds and records
# how many reviews were in flight when it started.
#   R1  K=3, 6 external PRs that each need a review: never more than 3 at once,
#       exactly 3 at the peak, 6 reviews in ONE tick; every PR's verdict is in
#       the state file (no worker's write lost to another's); one review row
#       opened and one closed per PR; the tick line says
#       concurrency=3 running=… started=6.
#   R2  two ticks at once on the same project: each (pr, head) is bought once;
#       the second tick stands down at the lane lock.
#   R3  paid once: every head already carries a verdict in the ledger, or this
#       lane's review on GitHub: zero agent calls, at K=3.
#   R4  free /tmp under REVIEW_TMP_MIN_MB: no worker starts, nothing is bought,
#       one alert line.
#   R5  the workers' scratch is gone: no pool dir left under tmp/.
#   R6  K=0 (no cap): 12 PRs that each need a review all run at once.
#   R7  an agent call answering 429: no verdict and no no-verdict strike, the
#       in-flight charge handed back, the pool pauses and the PRs after it wait
#       for a later tick; a tick inside the pause buys nothing.
# BH-5311: R1/R6 peaks are barrier-gated ($T/barrier), never a sleep race;
# the barrier gives up only after 60 s with no new start (BH-5544), and R6 also
# reads the pool's own `running=12 started=12`.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-parallel.bh-5284-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
[ -f "$SRC/bin/lib/review-pool.sh" ] || { echo "FAIL: bin/lib/review-pool.sh does not exist"; FAIL=1; }

PROJECT=project-1
SLUG=example-org/project-1
HEAD=ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12
NUMS="7 8 9 10 11 12"
H="$T/h"
STATE="$H/state/$PROJECT.pr-reviews.json"
MARKER="Automated harness review (Fable) of"
mkdir -p "$T/fakebin" "$T/log"
cp "$SRC/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
# BH-5311: RPP_GH_DELAY_S slows every gh read, the way a loaded CI runner does.
[ -n "${RPP_GH_DELAY_S:-}" ] && sleep "$RPP_GH_DELAY_S"
case "$*" in
  *"/pulls -f state=open"*) case "$*" in *"page=1"|*"page=1 "*) restpr --raw 200 "$(cat "$TEST_ROOT/prs.json")" ;;
      *) restpr --raw 200 '[]' ;; esac ;;
  *"pr diff"*"name-only"*) printf 'f.txt\n' ;;
  *"pr diff"*) printf 'diff --git a/f.txt b/f.txt\n+line 10 CHANGED BY PR\n' ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED"}\n' ;;
  *"pr view"*) printf '{"body":"test body","comments":[],"reviews":[]}\n' ;;
  *"pr review"*|*"pr comment"*) printf '%s\n' "$*" >> "$TEST_ROOT/gh-writes.log" ;;
  *"pr merge"*) : ;;
  *actions/runs*) printf '{"s":"completed","c":"success","n":"CI"}\n' ;;
  *"/reviews"*)
    n=$(printf '%s' "$*" | sed -E 's|.*pulls/([0-9]+)/reviews.*|\1|')
    [ -f "$TEST_ROOT/reviews.$n" ] && cat "$TEST_ROOT/reviews.$n" ;;
  *) : ;;
esac
exit 0
STUB
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
mb=\$(cat "$T/tmpfree" 2>/dev/null || echo 102400)
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 %s 1%% /tmp\n' "\$((mb * 1024))"
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/df"
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/meminfo"
# The jobs functions: one review row per paid review (review_claim), recorded.
cat > "$T/stub.sh" <<EOF
job_lane_open() { JOB_ID="job-\$2"; export JOB_ID; printf 'open %s\n' "\$2" >> "$T/log/rows"; return 0; }
job_lane_close() { [ -n "\${JOB_ID:-}" ] && printf 'close %s\n' "\$JOB_ID" >> "$T/log/rows"; JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
job_heartbeat() { return 0; }
job_update() { return 0; }
job_phase_open() { return 0; }
job_verdict_rebind() { return 0; }
EOF

fresh() { # fresh <state-json>
  scratch_rm "$H" 2>/dev/null
  rm -f "$T/log"/* "$T/gh-writes.log" "$T"/reviews.* "$T/tmpfree" "$T"/rl.* "$T/barrier"
  scratch_rm "$T/run" 2>/dev/null; mkdir -p "$T/run"
  mkdir -p "$H/bin" "$H/state" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/tmp"
  mkdir -p "$H/catalog/lanes.d"; cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
  cp "$SRC/bin/review-prs.sh" "$SRC/bin/fleet-conf.sh" "$H/bin/"
  scratch_install_closure bin/review-prs.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
  mrs_fixture "$H" "$PROJECT"
  cp "$T/stub.sh" "$H/bin/stub.sh"
  for b in beat.sh deploy-request.sh merge-queue.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$b"; chmod +x "$H/bin/$b"; done
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log/alerts"\n' "$T" > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
  cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
pr="\${AGENT_CALL_PR##*/}"
if [ -e "$T/rl.\$pr" ]; then
  printf '%s\n' "\${AGENT_CALL_FP:-}" >> "$T/log/sink"
  printf 'API Error: 429 rate_limit_error: Number of concurrent connections has exceeded your rate limit\n' > "\$5"
  exit 1
fi
( flock 9; : > "$T/run/\$pr"; ls "$T/run" | wc -l | tr -d ' ' >> "$T/log/conc"
  printf '%s\n' "\${AGENT_CALL_FP:-}" >> "$T/log/sink" ) 9>"$T/agent.lock"
# \$T/barrier = N: hold until N calls of this tick have started, so the first N
# overlap whatever the runner's start-up speed, and a peak below N can only be
# the pool's own cap. The bound is on a STALL, not on the total wait: the
# barrier waits while workers keep starting, however slowly the box starts
# them, and gives up only when no new call starts for RPP_BARRIER_STALL_POLLS
# polls of 0.1 s (default 600, at least 60 s), which is what a capped or serial
# pool does. A give-up writes \$T/log/barrier-gaveup, and every later call of
# the tick then skips the barrier, so a serial pool pays the stall once.
if [ -s "$T/barrier" ] && [ ! -e "$T/log/barrier-gaveup" ]; then
  want=\$(cat "$T/barrier"); last=0; idle=0
  while :; do
    n=\$(wc -l < "$T/log/conc" | tr -d ' ')
    [ "\$n" -ge "\$want" ] && break
    [ "\$n" -gt "\$last" ] && { last=\$n; idle=0; }
    if [ "\$idle" -ge "\${RPP_BARRIER_STALL_POLLS:-600}" ]; then
      printf '%s of %s started\n' "\$n" "\$want" >> "$T/log/barrier-gaveup"; break
    fi
    sleep 0.1; idle=\$((idle+1))
  done
fi
sleep "\$(cat "$T/sleep")"
printf 'claude\n' > "\$5.runner"; printf 'claude-fable-5-1\n' > "\$5.model"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "\$5"
( flock 9; rm -f "$T/run/\$pr" ) 9>"$T/agent.lock"
exit 0
EOF
  chmod +x "$H/bin/agent-call.sh"
  printf '%s\n' "$1" > "$STATE"
  jq -nc --arg h "$HEAD" --arg ns "$NUMS" '[$ns | split(" ")[] | tonumber
    | {number:., head:{sha:$h,ref:"feature"}, base:{ref:"main"}, user:{login:"externaldev",type:"User"},
       title:"Test PR \(.)", draft:false, state:"open", labels:[]}]' > "$T/prs.json"
  echo 1 > "$T/sleep"
}
run_rp() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$SRC/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="$T/no-repos" BASH_ENV="$H/bin/stub.sh" REVIEW_LIVE_CI=0 REVIEW_DEDUPE=0 \
      REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05 TMPDIR="$T/tmp-$1"
    mkdir -p "$TMPDIR"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED REVIEW_BOX_MAX REVIEW_TMP_MIN_MB REVIEW_POOL_TMP_PATH
    bash "$H/bin/review-prs.sh" "$PROJECT" > "$T/out.$1" 2>&1 )
}
LOG="$H/logs/pr-reviews.log"
cnt() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
calls() { cnt . "$T/log/sink"; }
peak() { sort -n "$T/log/conc" 2>/dev/null | tail -1; }

# ── R1: K=3 over 6 PRs that each need a review ──
# The first 3 calls wait for each other at the stub's barrier (see R6).
fresh '{}'; echo 3 > "$T/barrier"
REVIEW_CONCURRENCY=3 run_rp a
rm -f "$T/barrier"
[ "$(calls)" = 6 ] && ok || bad "R1 reviews bought=$(calls) (want 6): $(tail -20 "$LOG" 2>/dev/null)"
[ "$(peak)" = 3 ] && ok || bad "R1 peak in-flight=$(peak) (want 3): $(paste -sd' ' "$T/log/conc" 2>/dev/null)"
[ "$(sort -u "$T/log/sink" | wc -l | tr -d ' ')" = 6 ] && ok || bad "R1 a head was bought twice: $(sort "$T/log/sink" | uniq -d)"
for n in $NUMS; do
  [ "$(jq -r --arg n "$n" '.[$n].sha // ""' "$STATE")" = "$HEAD" ] && [ "$(jq -r --arg n "$n" '.[$n].verdict // ""' "$STATE")" = REQUEST_CHANGES ] \
    && ok || bad "R1 #$n's verdict is not in the state file (a lost write): $(cat "$STATE")"
done
[ "$(cnt '^open ' "$T/log/rows")" = 6 ] && [ "$(cnt '^close ' "$T/log/rows")" = 6 ] && ok \
  || bad "R1 review rows: $(sort "$T/log/rows" | paste -sd' ')"
grep -q "review-prs tick concurrency=3 running=[0-9]* started=6" "$LOG" && ok || bad "R1 no tick line: $(grep tick "$LOG")"
[ ! -s "$T/log/barrier-gaveup" ] && ok || bad "R1 the barrier stalled: $(head -n1 "$T/log/barrier-gaveup") — the pool stopped starting workers"
# R5: the scratch went with the workers
ls -d "$H/tmp"/review-prs-pool-* >/dev/null 2>&1 && bad "R5 pool dir left: $(ls "$H/tmp")" || ok
grep -qE '^(tmp\.|review-prs-)' <<<"$(ls "$T/tmp-a" 2>/dev/null)" && bad "R5 review temp files left in TMPDIR: $(ls "$T/tmp-a")" || ok

# ── R2: two ticks at once ──
fresh '{}'; echo 2 > "$T/sleep"
REVIEW_CONCURRENCY=3 run_rp b &
P2=$!
REVIEW_CONCURRENCY=3 run_rp c
wait "$P2"
[ "$(calls)" = 6 ] && ok || bad "R2 reviews bought=$(calls) over two ticks (want 6, one per head)"
[ "$(sort "$T/log/sink" | uniq -d | wc -l | tr -d ' ')" = 0 ] && ok || bad "R2 a head bought twice: $(sort "$T/log/sink" | uniq -d)"

# ── R3: paid once ──
# PRs 7-9 carry a verdict on this head in the ledger; 10-12 carry this lane's
# review of this head on GitHub (the BH-1017 receipt).
ST=$(jq -nc --arg h "$HEAD" '{"7":{sha:$h,verdict:"REQUEST_CHANGES"},"8":{sha:$h,verdict:"REQUEST_CHANGES"},"9":{sha:$h,verdict:"REQUEST_CHANGES"}}')
fresh "$ST"
for n in 10 11 12; do
  # BH-8419: this lane's review is the App's (cromford[bot]); operator is a person.
  printf '%s\t%s\t%s\n' 'cromford[bot]' CHANGES_REQUESTED \
    "$(printf 'Findings.\nVERDICT: REQUEST_CHANGES\n\n---\n_%s %s. Static review._' "$MARKER" "$HEAD" | base64 -w0)" > "$T/reviews.$n"
done
REVIEW_CONCURRENCY=3 run_rp d
[ "$(calls)" = 0 ] && ok || bad "R3 a paid head was bought again: $(cat "$T/log/sink" 2>/dev/null)"
for n in 10 11 12; do
  [ "$(jq -r --arg n "$n" '.[$n].sha // ""' "$STATE")" = "$HEAD" ] && ok || bad "R3 #$n not rehydrated: $(cat "$STATE")"
done

# ── R4: /tmp under the floor ──
fresh '{}'; echo 1000 > "$T/tmpfree"
REVIEW_CONCURRENCY=3 run_rp e
[ "$(calls)" = 0 ] && ok || bad "R4 bought with /tmp low: $(calls)"
grep -q 'no new worker: .* has 1000MB free, below REVIEW_TMP_MIN_MB=1536' "$LOG" && ok || bad "R4 no refusal line: $(tail -5 "$LOG")"
[ "$(cnt . "$T/log/alerts")" = 1 ] && ok || bad "R4 alerts=$(cnt . "$T/log/alerts") (want 1): $(cat "$T/log/alerts" 2>/dev/null)"

# ── R6: K=0 is no cap ──
# The stub holds each call at a 12-wide barrier: the peak used to depend on
# whether a busy runner started all 12 serialized workers inside one 2s sleep
# (CI saw 10 on main 5dca5f355). Memory and /tmp are already faked, so only the
# pool's own cap can now keep the peak under 12.
NUMS="7 8 9 10 11 12 13 14 15 16 17 18"; fresh '{}'; echo 2 > "$T/sleep"; echo 12 > "$T/barrier"
REVIEW_CONCURRENCY=0 run_rp f
[ "$(calls)" = 12 ] && ok || bad "R6 reviews bought=$(calls) (want 12)"
[ "$(peak)" = 12 ] && ok || bad "R6 peak in-flight=$(peak) (want all 12): $(paste -sd' ' "$T/log/conc" 2>/dev/null)"
[ ! -s "$T/log/barrier-gaveup" ] && ok || bad "R6 the barrier stalled: $(head -n1 "$T/log/barrier-gaveup") — the pool stopped starting workers"
# The pool's own count: RP_RUNNING_AT_CLOSE counts workers not yet collected,
# and none can end while the barrier holds, so all 12 are running at close.
grep -q "review-prs tick concurrency=[0-9]* running=12 started=12" "$LOG" && ok || bad "R6 the pool's tick line: $(grep tick "$LOG")"
NUMS="7 8 9 10 11 12"; rm -f "$T/barrier"

# ── R7: a 429 pauses starts and records nothing ──
fresh '{}'; : > "$T/rl.7"
REVIEW_CONCURRENCY=1 REVIEW_RATE_BACKOFF_S=60 run_rp g
[ "$(calls)" = 1 ] && ok || bad "R7 calls=$(calls) (want only #7's, then the pause)"
[ -z "$(jq -r '.["7"].verdict // ""' "$STATE")" ] && [ -z "$(jq -r '.["7"].noverdict // ""' "$STATE")" ] && ok \
  || bad "R7 a rate limit recorded a verdict or a no-verdict strike: $(cat "$STATE")"
[ "$(jq -r '.["7"].reviewing_attempts // 0' "$STATE")" = 0 ] && ok || bad "R7 the in-flight charge was not handed back: $(cat "$STATE")"
grep -q '#7 @ab12cd3 agent call hit a rate or concurrency limit (rc=1)' "$LOG" && ok || bad "R7 no limit line: $(tail -5 "$LOG")"
[ "$(cnt 'new starts paused for 60s' "$LOG")" = 1 ] && ok || bad "R7 pause lines: $(grep -c paused "$LOG")"
grep -q 'new starts paused [0-9]*s more after a rate limit; #8' "$LOG" && ok || bad "R7 #8 did not wait: $(tail -5 "$LOG")"
ls "$H/builds"/ext-*-noverdict >/dev/null 2>&1 && bad "R7 a no-verdict file was written for a rate limit" || ok
rm -f "$T/rl.7"; REVIEW_CONCURRENCY=1 run_rp h
[ "$(calls)" = 1 ] && ok || bad "R7 a tick inside the pause bought $(calls)"

echo "review-prs-parallel.bh-5284: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

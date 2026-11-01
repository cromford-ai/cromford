#!/bin/bash
# tests/execute-no-progress.bh-8868-test.sh — BH-8868: an execute session that
# changes no file is stopped early, with EXECUTE_NO_PROGRESS, and does not run
# on to its context ceiling.
#
# THE INCIDENT (project-6-os TK-3225). The execute session ran 3510 s and read
# 54.2M context tokens with 0 file changes, until `CONTEXT KILL ...
# ceiling=53600000`. Nothing stopped a session that wrote nothing.
#
# HOW. Cases 2-5 drive the REAL bin/agent-call.sh against a scratch $HARNESS
# with a fake `claude` on PATH (the tests/context-kill.bh-653-test.sh pattern):
# the fake grows a real-shaped session transcript, so the context meter reads a
# live session, and it runs in a scratch git worktree, so the no-progress check
# reads a real `git status`. NP_NOW moves the meter's clock forward ("now")
# without a 20-minute wait. Every assertion is about an artifact.
#   1 np_decide table (bin/lib/execute-no-progress.sh), pure.
#   2 time rule: stop, rc 143, NO PROGRESS: line, cost row note, no failover.
#   3 ceiling rule: stop at half the ceiling, before the context kill.
#   4 negative: a session that writes a new file is not stopped; a plan stage
#     is never armed; a non-git cwd is never armed.
#   5 knobs 0: no stop.
#   6 the REAL `# >>> execute result` block of bin/lib/rb/execute.sh with a
#     $BUILD/execute-run.txt.noprogress marker: RESULT, exit 5, transcript.
#   7 the knob file: both knobs, defaults 20 and 50, zero_means off.
#   8 vendor budget: the curl/wget stubs saw 0 calls.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/execute-no-progress.bh-8868-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
LIB="$DIR/bin/lib/execute-no-progress.sh"

# =============================================================================
# 1. THE DECISION TABLE. <elapsed_s> <total> <ceiling> <changed> <min> <pct> -> verdict
# =============================================================================
if [ -r "$LIB" ]; then
  # shellcheck disable=SC1090
  . "$LIB"
  dec() { np_decide "$@" 2>/dev/null | awk -F"\t" '{ print ($1 == "stop") ? $1 "\t" $2 : $1 }'; }
  while IFS='|' read -r args want; do
    # shellcheck disable=SC2086
    got=$(dec $args)
    [ "$got" = "$want" ] && ok || bad "1 np_decide $args: want '$want', got '$got'"
  done <<'EOF'
1200 1000000 53600000 0 20 50|stop	rule=time
300 26800000 53600000 0 20 50|stop	rule=ceiling
3510 54200000 53600000 0 20 50|stop	rule=time
1199 1000000 53600000 0 20 50|ok
1200 1000000 53600000 1 20 50|ok
300 26790000 53600000 0 20 50|ok
5000 1000000 53600000 0 0 50|ok
300 30000000 53600000 0 20 0|ok
300 30000000 0 0 20 50|ok
abc 30000000 53600000 0 20 50|stop	rule=ceiling
1200 x 53600000 0 20 50|stop	rule=time
x x x 0 20 50|ok
1200 1000000 53600000 x 20 50|ok
EOF
else
  bad "1 missing bin/lib/execute-no-progress.sh"
fi

# =============================================================================
# The driven fixture: a scratch harness, a fake claude, a scratch worktree.
# =============================================================================
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/.claude/projects/-work" "$T/notgit"
cat > "$T/budgets.json" <<'EOF'
{
  "_units": "input_toks + cache_read",
  "lanes": [
    {"lane":"np-exec","stage":"execute","project":"testproj","ceiling_tokens":200000,
     "target_tokens":1000,"context_kill_tokens":100000,"composition":[],
     "bounds":["[lane:context_kill] test fixture PENDING"]},
    {"lane":"np-plan","stage":"plan","project":"testproj","ceiling_tokens":200000,
     "target_tokens":1000,"context_kill_tokens":100000,"composition":[],
     "bounds":["[lane:context_kill] test fixture PENDING"]}
  ]
}
EOF
# STUB_ENTRIES entries of STUB_TOKS input tokens, one every 0.2 s. STUB_WRITE_AT
# = the entry after which the stub creates a new untracked file in its cwd.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
echo $$ > "$T_DIR/child.pid"
echo "claude $sid" >> "$T_DIR/claude-calls.log"
PROJ="$HOME/.claude/projects/-work"
mkdir -p "$PROJ"
n=0
while [ "$n" -lt "${STUB_ENTRIES:-40}" ]; do
  n=$((n+1))
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-10-31T18:00:00Z","message":{"id":"msg_%s","model":"claude-fable-5-1","usage":{"input_tokens":%s,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" "${STUB_TOKS:-1000}" >> "$PROJ/$sid.jsonl"
  [ "$n" = "${STUB_WRITE_AT:-x}" ] && echo "work" > "$PWD/new-source-file.txt"
  sleep 0.2
done
printf '{"result":"CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
chmod +x "$T/fakebin/claude"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"
for v in curl wget grok; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$v" "$T" > "$T/fakebin/$v"
  chmod +x "$T/fakebin/$v"
done
: > "$T/net.log"; : > "$T/claude-calls.log"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"; chmod +x "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

new_wt() { # new_wt <dir> — a git worktree with one commit
  mkdir -p "$1"
  git -C "$1" init -q 2>/dev/null
  printf 'base\n' > "$1/README.md"
  git -C "$1" add README.md && git -C "$1" -c user.email=t@t -c user.name=t commit -qm base
}
# run_call <outfile> <stage> <cwd> [env assignments...] ; echoes the rc
run_call() {
  local out="$1" stage="$2" cwd="$3"; shift 3
  rm -f "$out" "$out".* "$T/child.pid"
  ( cd "$cwd" || exit 99
    export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$T/budgets.json" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 CALL_GUARD=0 LADDER_TIER2_GROK=0
    unset AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET NP_NOW \
          EXECUTE_NO_WRITE_STOP_MIN EXECUTE_NO_WRITE_STOP_CEILING_PCT
    env "$@" bash "$DIR/bin/agent-call.sh" "$stage" testproj claude-fable-5-1 60 "$out" "execute $out" \
      >/dev/null 2>&1 )
  echo $?
}
child_alive() { local p; p=$(cat "$T/child.pid" 2>/dev/null) || return 1; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
sid_of() { sed -n 's/.*session=\([0-9a-f-]*\).*/\1/p' "$1" 2>/dev/null; }
entries() { local c; c=$(grep -c '"usage"' "$T/.claude/projects/-work/$1.jsonl" 2>/dev/null); echo "${c:-0}"; }
col() { cut -d, -f"$2" <<<"$1"; }
FUTURE=$(( $(date -u +%s) + 1300 ))

# =============================================================================
# 2. TIME RULE. 150 x 300 tokens stays under half the 100,000 ceiling; the
#    clock says 21+ minutes passed; no file was written.
# =============================================================================
: > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; : > "$T/logs/cost.csv"
new_wt "$T/wt2"
RC2=$(run_call "$T/out.time" execute "$T/wt2" NP_NOW="$FUTURE" STUB_ENTRIES=150 STUB_TOKS=300)
NP2=$(cat "$T/out.time.noprogress" 2>/dev/null)
grep -q 'rule=time' <<<"$NP2" && ok || bad "2 no \$OUT.noprogress with rule=time: '${NP2:-<none>}'"
[ "$RC2" = 143 ] && ok || bad "2 a no-progress stop must be rc 143, got $RC2"
child_alive && bad "2 the stub is still running after the stop" || ok
SID2=$(sid_of "$T/out.time.noprogress")
[ -n "$SID2" ] && [ "$(entries "$SID2")" -lt 150 ] && ok || bad "2 the stub ran to completion ($(entries "$SID2") entries) — it was never stopped"
tail -1 "$T/out.time" 2>/dev/null | grep -q '^NO PROGRESS: execute/testproj' && ok || bad "2 \$OUT's last line is not the NO PROGRESS: notice: $(tail -1 "$T/out.time" 2>/dev/null)"
[ ! -f "$T/out.time.ctxkill" ] && ok || bad "2 a context kill fired — the stop did not come before the ceiling"
ROW=$(grep ',execute,claude,' "$T/logs/cost.csv" 2>/dev/null | tail -1)
case "$(col "$ROW" 24)" in *no-progress:rule=time:elapsed_s=*) ok ;; *) bad "2 cost row note is '$(col "$ROW" 24)', want no-progress:rule=time:elapsed_s=..." ;; esac
[ "$(col "$ROW" 18)" = killed ] && ok || bad "2 cost row_source is '$(col "$ROW" 18)', want killed"
grep -q 'retrying as' "$T/logs/failovers.log" && bad "2 the stopped session was retried on another model" || ok
grep -q 'one retry on the SAME lane' "$T/logs/failovers.log" && bad "2 the stop was treated as an external kill and retried" || ok
grep -q 'no-progress stop' "$T/logs/failovers.log" && ok || bad "2 no failovers.log record of the policy stop: $(cat "$T/logs/failovers.log")"
grep -q 'BUDGET STOP' "$T/logs/ALERTS.log" && bad "2 a no-progress stop wrote a BUDGET STOP alert: $(cat "$T/logs/ALERTS.log")" || ok
[ "$(grep -c "^claude " "$T/claude-calls.log")" = 1 ] && ok || bad "2 want exactly one claude call, got $(grep -c "^claude " "$T/claude-calls.log")"

# =============================================================================
# 3. CEILING RULE. 5,000 tokens an entry: half the ceiling after 10 entries,
#    the context kill after 20. The no-progress stop comes first.
# =============================================================================
new_wt "$T/wt3"
RC3=$(run_call "$T/out.ceil" execute "$T/wt3" STUB_TOKS=5000)
NP3=$(cat "$T/out.ceil.noprogress" 2>/dev/null)
grep -q 'rule=ceiling' <<<"$NP3" && ok || bad "3 no \$OUT.noprogress with rule=ceiling: '${NP3:-<none>}'"
[ ! -f "$T/out.ceil.ctxkill" ] && ok || bad "3 the context kill fired — the session ran on to the ceiling"
T3=$(sed -n 's/.*total=\([0-9]*\).*/\1/p' <<<"$NP3")
[ -n "$T3" ] && [ "$T3" -ge 50000 ] && [ "$T3" -le 100000 ] && ok || bad "3 the stop total ($T3) is not between half the ceiling and the ceiling"
[ "$RC3" = 143 ] && ok || bad "3 want rc 143, got $RC3"

# =============================================================================
# 4. NEGATIVES. A session that writes a new file; a plan stage; a non-git cwd.
# =============================================================================
new_wt "$T/wt4"
RC4=$(run_call "$T/out.write" execute "$T/wt4" NP_NOW="$FUTURE" STUB_ENTRIES=12 STUB_WRITE_AT=2)
[ ! -f "$T/out.write.noprogress" ] && ok || bad "4 a session that created a new file was stopped: $(cat "$T/out.write.noprogress")"
[ "$RC4" = 0 ] && ok || bad "4 the writing session must finish rc 0, got $RC4"
[ "$(cat "$T/out.write" 2>/dev/null)" = "CLEAN DONE" ] && ok || bad "4 the writing session's output changed: $(cat "$T/out.write" 2>/dev/null)"
new_wt "$T/wt4b"
RC4B=$(run_call "$T/out.plan" plan "$T/wt4b" NP_NOW="$FUTURE" STUB_ENTRIES=12)
[ ! -f "$T/out.plan.noprogress" ] && [ "$RC4B" = 0 ] && ok || bad "4 a plan stage was stopped (rc $RC4B)"
RC4C=$(run_call "$T/out.ng" execute "$T/notgit" NP_NOW="$FUTURE" STUB_ENTRIES=12)
[ ! -f "$T/out.ng.noprogress" ] && [ "$RC4C" = 0 ] && ok || bad "4 a non-git cwd was stopped (rc $RC4C)"

# =============================================================================
# 5. KNOBS 0: both rules off.
# =============================================================================
new_wt "$T/wt5"
RC5=$(run_call "$T/out.off" execute "$T/wt5" NP_NOW="$FUTURE" STUB_TOKS=3000 STUB_ENTRIES=15 \
  EXECUTE_NO_WRITE_STOP_MIN=0 EXECUTE_NO_WRITE_STOP_CEILING_PCT=0)
[ ! -f "$T/out.off.noprogress" ] && [ "$RC5" = 0 ] && ok || bad "5 knobs 0 must turn the stop off (rc $RC5, marker: $(cat "$T/out.off.noprogress" 2>/dev/null))"

# =============================================================================
# 6. THE EXECUTE RESULT BLOCK with the marker.
# =============================================================================
awk 'index($0,"# >>> execute result")==1{f=1;next} index($0,"# <<< execute result")==1{exit} f' \
  "$DIR/bin/lib/rb/execute.sh" > "$T/exec.sh"
B6="$T/b6"; mkdir -p "$B6" "$T/envdir"; : > "$T/envdir/global.env"
printf 'I am still reading the plan.\n' > "$B6/execute-run.txt"
printf 'rule=time elapsed_s=1260 total=1200000 ceiling=53600000 min=20 pct=50 session=abc\n' > "$B6/execute-run.txt.noprogress"
( set -uo pipefail
  PROJECT=project-6-os; KEY=TK-3225; BASE=main; BRANCH=ticket/TK-3225; BUILD="$B6"
  HARNESS="$DIR" CLAUDE_PROJECTS_DIR="$T/projects" HARNESS_ENV_DIR="$T/envdir" ETC_HARNESS_ENV="$T/envdir" HOME="$T/home6"
  export HARNESS CLAUDE_PROJECTS_DIR HARNESS_ENV_DIR ETC_HARNESS_ENV HOME
  STAMP() { echo TS; }
  RESULT() { echo "$*" > "$BUILD/RESULT"; }
  STAGE_LANE_DEFER() { :; }
  CKPT_STOP() { :; }; CKPT_NONWIP_COUNT() { echo 1; }; CKPT_WIP_COUNT() { echo 0; }
  CKPT_SQUASH_WIP() { echo squashed > "$BUILD/squashed"; }
  git() { return 1; }   # the branch carries a diff: only the marker can end the build
  # shellcheck disable=SC1090
  . "$T/exec.sh" ) >/dev/null 2>&1
RC6=$?
[ "$RC6" = 5 ] && ok || bad "6 the execute result block must exit 5 on the marker, got $RC6"
R6=$(head -1 "$B6/RESULT" 2>/dev/null)
case "$R6" in "EXECUTE_EMPTY EXECUTE_NO_PROGRESS: time after 1260s, 1200000 of 53600000 context tokens, 0 files changed"*) ok ;;
  *) bad "6 RESULT line 1 is '$R6'" ;; esac
[ "$(head -1 "$B6/execute-transcript.md" 2>/dev/null)" = "# execute transcript (EXECUTE_NO_PROGRESS)" ] \
  && ok || bad "6 no execute-transcript.md with the EXECUTE_NO_PROGRESS title: $(head -1 "$B6/execute-transcript.md" 2>/dev/null)"
[ ! -e "$B6/squashed" ] && ok || bad "6 the build went on past the marker to the squash"
grep -q 'EXECUTE_NO_PROGRESS' "$B6/pipeline.log" 2>/dev/null && ok || bad "6 no pipeline.log line for the stop"

# =============================================================================
# 7. THE KNOB FILE.
# =============================================================================
KF="$DIR/catalog/lanes.d/_lib.execute-no-progress.json"
[ "$(jq -r '.libs[0].knobs[] | select(.env=="EXECUTE_NO_WRITE_STOP_MIN") | "\(.default) \(.zero_means)"' "$KF" 2>/dev/null)" = "20 off" ] \
  && ok || bad "7 EXECUTE_NO_WRITE_STOP_MIN must default 20, zero_means off"
[ "$(jq -r '.libs[0].knobs[] | select(.env=="EXECUTE_NO_WRITE_STOP_CEILING_PCT") | "\(.default) \(.zero_means)"' "$KF" 2>/dev/null)" = "50 off" ] \
  && ok || bad "7 EXECUTE_NO_WRITE_STOP_CEILING_PCT must default 50, zero_means off"
[ "$(jq -r '.libs[0].file' "$KF" 2>/dev/null)" = bin/lib/execute-no-progress.sh ] && ok || bad "7 the knob file must name the lib"

# =============================================================================
# 8. VENDOR BUDGET: only the fake claude ran.
# =============================================================================
[ ! -s "$T/net.log" ] && ok || bad "8 a network/vendor stub was called: $(cat "$T/net.log")"

echo "execute-no-progress.bh-8868-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/context-kill-row-source.bh-3990-test.sh — WHICH ROW A STOPPED CALL
# WRITES (BH-3990), driven through the real bin/agent-call.sh.
#
# The context meter is the one stop that can land AFTER a vendor call started:
# it only fires once the session transcript shows billed API responses. So its
# row keeps whatever usage the transcript reports and says row_source=killed.
# Every other stop (context-kill repeat, call-guard) refuses BEFORE the runner
# starts: row_source=refused, zero tokens, the runner never invoked.
#
#   a  a killed session: killed, input_toks = the transcript's sum, cost > 0
#   b  a cliff-lowered kill: killed, note cliff-avoided:
#   c  a killed session whose transcript is gone by row time: killed, token
#      columns BLANK (unmeasured), never 0
#   d  the same lane under its ceiling: transcript, never killed
#   e  an external TERM with no $OUT.ctxkill (rc 143): not killed
#   f  context-kill repeat refusal: refused, 0 tokens, 0 cost, runner not run
#   g  call-guard repeat refusal: refused, 0 tokens, 0 cost, runner not run
#
# The fake claude is tests/context-kill.bh-653-test.sh's: it grows a real
# session transcript (5,000 input tokens per entry) that the meter reads.
# Run from anywhere: tests/context-kill-row-source.bh-3990-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-9536: the meter default is alert; this suite pins the kill mode
export CONTEXT_KILL_MODE=kill
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin/lib/jobs" "$T/fakebin" "$T/noenv" "$T/.claude/projects/-work"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/budgets.json" <<'EOF'
{
  "_units": "input_toks + cache_read",
  "lanes": [
    {"lane":"kill-lane","stage":"eval","project":"testproj","ceiling_tokens":200000,
     "target_tokens":1000,"context_kill_tokens":100000,"composition":[],
     "bounds":["[lane:context_kill] test fixture PENDING"]}
  ]
}
EOF

# STUB_ON_TERM: what the stub does when TERM reaches it.
#   (unset) die with the default action (rc 143)
#   wipe    delete its own transcript, then exit 143 with no envelope
# STUB_SELF_TERM=<n>: after entry n, the stub TERMs ITSELF (an external kill
# that is not the meter's).
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
echo $$ > "$T_DIR/child.pid"
PROJ="$HOME/.claude/projects/-work"
mkdir -p "$PROJ"
[ "${STUB_ON_TERM:-}" = wipe ] && trap 'rm -f "$PROJ/$sid.jsonl"; exit 143' TERM
n=0
while [ "$n" -lt "${STUB_ENTRIES:-10}" ]; do
  n=$((n+1))
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-10-03T18:00:00Z","message":{"id":"msg_%s","model":"claude-fable-5-1","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" >> "$PROJ/$sid.jsonl"
  [ -n "${STUB_SELF_TERM:-}" ] && [ "$n" -ge "$STUB_SELF_TERM" ] && kill -TERM $$
  sleep 0.2
done
printf '{"result":"CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The call-guard worker for (g): every claim is refused at 2 paid of 2.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--data-binary|-m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */api/call-guard/claim) printf '{"allowed":false,"count":2,"max":2,"call_id":"x","top":[]}\n200' ;;
  */api/call-guard/*) printf '{"settled":true}\n200' ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$T/fakebin/"*
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
chmod +x "$T/bin/"*.sh
# The real jobs client, so (g)'s claim rides the transport that ships.
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh"
mkdir -p "$T/state/model-routes"
for key in claude.ladder claude.ladder@testproj; do
  printf '0\tclaude-fable-5-1\tclaude\n' > "$T/state/model-routes/$key.tsv"
done

run_call() { # run_call <outfile> [env assignments...] ; echoes the rc
  local out="$1"; shift
  rm -f "$out" "$out.json" "$out.err" "$out.ctxkill" "$out.cliffcap" "$T/child.pid"
  scratch_rm "$T/.claude/projects/-work"; mkdir -p "$T/.claude/projects/-work"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$T/budgets.json" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 HARNESS_ENV_DIR="$T/noenv" LADDER_TIER2_GROK=0 \
           LADDER_SAME_RETRIES=0 LADDER_BACKOFF_SECS=0
    unset HARNESS_SECRET JOBS_URL CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_CLIFF \
          AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET CALL_GUARD CALL_GUARD_STAGES
    env "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5-1 60 "$out" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
col() { python3 -c 'import csv,sys; r=list(csv.reader([sys.argv[1]])); print(r[0][int(sys.argv[2])-1] if r and len(r[0])>=int(sys.argv[2]) else "")' "$1" "$2"; }
last_row() { grep ',testproj,eval,' "$T/logs/cost.csv" 2>/dev/null | tail -1; }
# The transcript's own input sum, read the way the meter reads it.
transcript_in() { jq -s '[.[]|.message.usage.input_tokens]|add' "$T/.claude/projects/-work/$1.jsonl" 2>/dev/null; }

# --- a: the meter kills a started session ------------------------------------
: > "$T/logs/cost.csv"
RC=$(run_call "$T/out.a" STUB_ENTRIES=40)
ROW=$(last_row)
SID=$(sed -n 's/.*session=\([0-9a-f-]*\).*/\1/p' "$T/out.a.ctxkill" 2>/dev/null)
[ "$RC" != 0 ] && [ -f "$T/out.a.ctxkill" ] \
  && ok || bad "a: the fixture session was not killed (rc=$RC, marker $( [ -f "$T/out.a.ctxkill" ] && echo yes || echo no))"
[ "$(col "$ROW" 18)" = killed ] \
  && ok || bad "a: a context-killed call's row_source is '$(col "$ROW" 18)', want killed: $ROW"
TIN=$(transcript_in "$SID")
[ -n "$TIN" ] && [ "$TIN" -gt 0 ] && [ "$(col "$ROW" 9)" = "$TIN" ] \
  && ok || bad "a: input_toks '$(col "$ROW" 9)' is not the transcript's sum '$TIN' — the partial usage was not kept"
awk -v c="$(col "$ROW" 13)" 'BEGIN{exit !(c+0 > 0)}' \
  && ok || bad "a: the killed row's cost_usd is '$(col "$ROW" 13)', want > 0 (it was billed)"
case "$(col "$ROW" 24)" in context-kill:ceiling=100000:*) ok ;; *) bad "a: note is '$(col "$ROW" 24)', want context-kill:ceiling=100000:..." ;; esac

# --- b: a ceiling the price cliff lowered ------------------------------------
jq '.per_token["claude-fable-5-1"].cliff_tokens = 60000' "$DIR/catalog/model-prices.json" > "$T/prices.json"
: > "$T/logs/cost.csv"
RC=$(run_call "$T/out.b" STUB_ENTRIES=40 CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000 MODEL_PRICES="$T/prices.json")
ROW=$(last_row)
[ "$(col "$ROW" 18)" = killed ] \
  && ok || bad "b: a cliff-avoided kill's row_source is '$(col "$ROW" 18)', want killed: $ROW"
case "$(col "$ROW" 24)" in *cliff-avoided:ceiling=50000:*) ok ;; *) bad "b: note is '$(col "$ROW" 24)', want cliff-avoided:ceiling=50000:..." ;; esac
[ -n "$(col "$ROW" 9)" ] && [ "$(col "$ROW" 9)" -gt 0 ] \
  && ok || bad "b: the cliff kill's row lost its input tokens: '$(col "$ROW" 9)'"

# --- c: killed, and nothing left to read the usage from ----------------------
: > "$T/logs/cost.csv"
RC=$(run_call "$T/out.c" STUB_ENTRIES=40 STUB_ON_TERM=wipe)
ROW=$(last_row)
[ -f "$T/out.c.ctxkill" ] \
  && ok || bad "c: fixture: the session was not killed"
[ "$(col "$ROW" 18)" = killed ] \
  && ok || bad "c: an unreadable killed session's row_source is '$(col "$ROW" 18)', want killed: $ROW"
[ "$(col "$ROW" 9)|$(col "$ROW" 10)|$(col "$ROW" 11)|$(col "$ROW" 12)" = "|||" ] \
  && ok || bad "c: an unmeasured killed row carries token values '$(col "$ROW" 9)|$(col "$ROW" 10)|$(col "$ROW" 11)|$(col "$ROW" 12)', want blank — zero is a claim nobody measured"

# --- d: under the ceiling ----------------------------------------------------
: > "$T/logs/cost.csv"
RC=$(run_call "$T/out.d" STUB_ENTRIES=5)
ROW=$(last_row)
[ "$RC" = 0 ] && [ "$(col "$ROW" 18)" = transcript ] \
  && ok || bad "d: a clean call under its ceiling: rc=$RC row_source='$(col "$ROW" 18)', want 0 and transcript"

# --- e: an external TERM, no marker ------------------------------------------
: > "$T/logs/cost.csv"
RC=$(run_call "$T/out.e" STUB_ENTRIES=5 STUB_SELF_TERM=3)
ROW=$(last_row)
[ ! -f "$T/out.e.ctxkill" ] && [ "$(col "$ROW" 7)" != 0 ] \
  && ok || bad "e: fixture: want a non-zero rc and no marker (rc col '$(col "$ROW" 7)')"
[ -n "$ROW" ] && [ "$(col "$ROW" 18)" != killed ] \
  && ok || bad "e: an external TERM was labelled killed (the label must come from \$OUT.ctxkill, never the rc): $ROW"

# --- f: the context-kill repeat refusal, before the runner -------------------
NOWTS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
: > "$T/logs/cost.csv"
for i in 1 2; do
  printf '%s\n' "$NOWTS,box,testproj,eval,claude,claude-fable-5-1,143,60,200000,10,0,0,1.00,subscription,none,unknown,s-$i,killed,,,,,,context-kill:ceiling=100000:total=200000:tk=BH-9:fp=," >> "$T/logs/cost.csv"
done
RC=$(run_call "$T/out.f" STUB_ENTRIES=5 AGENT_CALL_TICKET=BH-9)
ROW=$(last_row)
[ "$RC" = 74 ] && [ ! -e "$T/child.pid" ] \
  && ok || bad "f: the repeat was not refused before the runner (rc=$RC, runner ran: $( [ -e "$T/child.pid" ] && echo yes || echo no))"
[ "$(col "$ROW" 18)" = refused ] && [ "$(col "$ROW" 24)" = refused:context-kill-repeat ] \
  && ok || bad "f: the refusal row is '$(col "$ROW" 18)' / '$(col "$ROW" 24)', want refused / refused:context-kill-repeat: $ROW"
[ "$(col "$ROW" 9),$(col "$ROW" 10),$(col "$ROW" 11),$(col "$ROW" 12),$(col "$ROW" 13)" = "0,0,0,0,0" ] \
  && ok || bad "f: a pre-call refusal is not zero tokens, zero cost: $ROW"

# --- g: the call-guard repeat refusal, before the runner ---------------------
: > "$T/logs/cost.csv"
RC=$(run_call "$T/out.g" STUB_ENTRIES=5 JOBS_URL=https://jobs.test HARNESS_SECRET=s JOBS_RETRIES=0 CALL_GUARD_STAGES=eval)
ROW=$(last_row)
[ "$RC" = 74 ] && [ ! -e "$T/child.pid" ] \
  && ok || bad "g: the call-guard repeat was not refused before the runner (rc=$RC, \$OUT: $(head -1 "$T/out.g" 2>/dev/null))"
[ "$(col "$ROW" 18)" = refused ] && [ "$(col "$ROW" 24)" = refused:call-guard:repeat ] \
  && ok || bad "g: the refusal row is '$(col "$ROW" 18)' / '$(col "$ROW" 24)', want refused / refused:call-guard:repeat: $ROW"
[ "$(col "$ROW" 9),$(col "$ROW" 10),$(col "$ROW" 11),$(col "$ROW" 12),$(col "$ROW" 13)" = "0,0,0,0,0" ] \
  && ok || bad "g: a pre-call refusal is not zero tokens, zero cost: $ROW"

echo "context-kill-row-source.bh-3990-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

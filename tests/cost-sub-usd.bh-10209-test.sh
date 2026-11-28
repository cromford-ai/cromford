#!/bin/bash
# tests/cost-sub-usd.bh-10209-test.sh — the `sub_usd:<x>` note token on a
# claude cost row (BH-10209).
#
# Each transcript-priced claude row carries the subagent part of its dollars
# as the FIRST note token, so the daily digest can report the subagent share
# of execute spend without a new cost_rows column.
#
#   T1-T6  cost_sub_usd_token: a decimal prints the token (a measured zero
#          too); empty and anything else print nothing, rc 1.
#   A1     cost_row_source (extracted) with the REAL transcript-cost.sh on a
#          session with a subagents dir: SUB_USD_SEEN = the subagent dollars,
#          USD = the total.
#   A2     an old helper that prints no sub_usd field: SUB_USD_SEEN empty, the
#          rest as before.
#   A3     no transcript (the envelope row): SUB_USD_SEEN empty.
#   A4     bin/agent-call.sh DRIVEN with a fake claude that writes a main
#          transcript and a subagents file: the cost.csv row's note starts
#          with sub_usd:<the subagent dollars>, and cost_usd holds the total.
#   R1     round trip: cost_sub_usd_token -> cost_csv_field ->
#          dora_subagent.parse_sub_usd gives the same value.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "jq/python3 missing — skipping"; exit 0; }

# shellcheck source=../bin/lib/cost-row.sh
. "$DIR/bin/lib/cost-row.sh" || { echo "FAIL: cannot source bin/lib/cost-row.sh"; exit 1; }

echo "--- T1-T6. cost_sub_usd_token"
if command -v cost_sub_usd_token >/dev/null 2>&1; then
  O=$(cost_sub_usd_token 1.25); R=$?;     eq "T1 1.25" "$O|$R" "sub_usd:1.25|0"
  O=$(cost_sub_usd_token 0.000000); R=$?; eq "T2 a measured zero" "$O|$R" "sub_usd:0.000000|0"
  O=$(cost_sub_usd_token ""); R=$?;       eq "T3 empty" "$O|$R" "|1"
  O=$(cost_sub_usd_token -1); R=$?;       eq "T4 -1" "$O|$R" "|1"
  O=$(cost_sub_usd_token abc); R=$?;      eq "T5 abc" "$O|$R" "|1"
  O=$(cost_sub_usd_token 1.2.3); R=$?;    eq "T6 1.2.3" "$O|$R" "|1"
  O=$(cost_sub_usd_token 7); R=$?;        eq "T6b an integer" "$O|$R" "sub_usd:7|0"
  O=$(cost_sub_usd_token .5); R=$?;       eq "T6c no leading digit" "$O|$R" "|1"
else
  bad "T1-T6 cost_sub_usd_token is not defined in bin/lib/cost-row.sh"
fi

# Fixture prices and a session with a subagents dir (CLI 2.1.331 layout).
cat > "$T/prices.json" <<'JSON'
{"per_token":{
  "test-model": {"prompt":0.00001,"completion":0.00002,"cache_read":0.000001,"cache_write":0.0000125},
  "test-haiku": {"prompt":0.000001,"completion":0.000005,"cache_read":0.0000001,"cache_write":0.00000125}
}}
JSON
# entry <file> <id> <model> <in> <out> [extra-json]
entry() {
  mkdir -p "$(dirname "$1")"
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-11-26T10:00:00Z","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}%s}\n' \
    "$2" "$2" "$3" "$4" "$5" "${6:+,$6}" >> "$1"
}
SID=sess-bh10209-sub-usd
PROJ="$T/cfg/projects/-work"
entry "$PROJ/$SID.jsonl" m1 test-model 100 100              # $0.003
entry "$PROJ/$SID/subagents/agent-a.jsonl" s1 test-haiku 1000 1000 "\"isSidechain\":true,\"sessionId\":\"$SID\""  # $0.006

# cost_row_source, extracted as tests/transcript-cost-test.sh extracts it.
mkdir -p "$T/bin" "$T/logs" "$T/flags"
awk '/^# >>> cost_row_source/{f=1;next} /^# <<< cost_row_source/{exit} f' \
  "$DIR/bin/agent-call.sh" > "$T/bin/fn.sh"
grep -q 'cost_row_source()' "$T/bin/fn.sh" && ok || bad "could not extract cost_row_source"
# src_run <session-id> — prints IN|USD|ROW_SRC|SUB_USD_SEEN|PRICE_V_SEEN
src_run() {
  HARNESS="$T" PROJECT=demo STAGE=execute \
  bash -c '
    . "$0"
    . "'"$DIR"'/bin/lib/cost-row.sh"
    STAMP() { echo 2026-11-26T10:00:00Z; }
    IN=""; OUTT=""; CR=""; CW=""; USD=""; ROW_SRC=none; rmodel=asked-for
    SUB_USD_SEEN=unset; PRICE_V_SEEN=unset
    cost_row_source claude "$1" /work
    printf "%s|%s|%s|%s|%s\n" "$IN" "$USD" "$ROW_SRC" "$SUB_USD_SEEN" "$PRICE_V_SEEN"
  ' "$T/bin/fn.sh" "$1"
}

echo "--- A1. cost_row_source with the real transcript-cost.sh"
cat > "$T/bin/transcript-cost.sh" <<SH
#!/bin/bash
exec "$DIR/bin/transcript-cost.sh" "\$@" --config-dir "$T/cfg" --prices "$T/prices.json"
SH
chmod +x "$T/bin/transcript-cost.sh"
eq "A1 the row reads the subagent dollars" "$(src_run "$SID")" "1100|0.009000|transcript|0.006000|"

echo "--- A2. an old helper prints no sub_usd field"
printf '#!/bin/bash\necho "5|6|7|8|1.500000|really-ran|3|1||4"\n' > "$T/bin/transcript-cost.sh"
eq "A2 SUB_USD_SEEN empty, the version kept" "$(src_run "$SID")" "5|1.500000|transcript||4"

echo "--- A3. no transcript: the envelope row"
printf '#!/bin/bash\nexit 3\n' > "$T/bin/transcript-cost.sh"
eq "A3 no token on an envelope row" "$(R_IN=11 R_USD=0.90 src_run "$SID")" "11|0.90|result|unset|unset"

echo "--- A4. bin/agent-call.sh (driven, claude, a subagent)"
H="$T/h4"
mkdir -p "$H/logs" "$H/locks" "$H/flags" "$H/state/model-routes" "$H/bin/lib" "$H/noenv" "$H/.claude/projects" "$H/work"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "A4 could not install the jobs client closure"
printf '#!/bin/bash\necho subscription\n' > "$H/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/billing-mode.sh" "$H/bin/beat.sh"
for key in claude.ladder claude.ladder@testproj; do
  printf '0\t%s\tclaude\n' test-model > "$H/state/model-routes/$key.tsv"
done
cp "$T/prices.json" "$H/state/model-prices.json"
mkdir -p "$T/fakebin"
# The fake claude writes the main transcript and one subagent file for its
# --session-id, then the result envelope.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJ="$CFG/projects/$(pwd -P | tr '/' '-')"
[ -n "$sid" ] || sid="cli-chosen-$$"
mkdir -p "$PROJ/$sid/subagents"
printf '{"type":"assistant","uuid":"u-1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"msg_1","model":"test-model","usage":{"input_tokens":100,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$PROJ/$sid.jsonl"
for n in 1 2; do
  printf '{"type":"assistant","isSidechain":true,"sessionId":"%s","uuid":"s-%s","timestamp":"2026-11-26T10:00:01Z","message":{"id":"msg_sub","model":"test-haiku","usage":{"input_tokens":1000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$sid" "$n" >> "$PROJ/$sid/subagents/agent-x.jsonl"
done
printf '{"agentType":"general-purpose","model":"haiku"}\n' > "$PROJ/$sid/subagents/agent-x.meta.json"
cat >/dev/null 2>&1
printf '{"result":"DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.001}\n' "$sid"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/"*
drive_ac() { # drive_ac [ENV=VAL ...]; echoes rc
  rm -f "$H/logs/cost.csv"; scratch_rm "$H/.claude/projects"; mkdir -p "$H/.claude/projects"
  ( cd "$H/work" || exit 9
    unset HARNESS_SECRET JOBS_URL MODEL_PRICES CLAUDE_CONFIG_DIR CONTEXT_KILL CONTEXT_KILL_TOKENS \
          AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET CALL_GUARD CALL_GUARD_STAGES
    export PATH="$T/fakebin:$PATH" HARNESS="$H" HOME="$H" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" COST_TRANSCRIPT_ROWS=1 \
           HARNESS_ENV_DIR="$H/noenv" LADDER_TIER2_GROK=0 LADDER_SAME_RETRIES=0 LADDER_BACKOFF_SECS=0
    for kv in "$@"; do export "${kv?}"; done
    bash "$DIR/bin/agent-call.sh" execute testproj test-model 60 "$H/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
csvcol() { python3 -c 'import csv,sys
rows=[r for r in csv.reader(open(sys.argv[1])) if len(r)>5 and r[3]==sys.argv[3]]
print(rows[-1][int(sys.argv[2])-1] if rows and len(rows[-1])>=int(sys.argv[2]) else "")' "$1" "$2" "${3:-execute}" 2>/dev/null; }
RC=$(drive_ac)
eq "A4 rc" "$RC" 0
eq "A4 row_source" "$(csvcol "$H/logs/cost.csv" 18)" transcript
eq "A4 cost_usd = main 0.003 + subagent 0.006" "$(csvcol "$H/logs/cost.csv" 13)" 0.009000
eq "A4 model column = the main session's" "$(csvcol "$H/logs/cost.csv" 6)" test-model
NOTE=$(csvcol "$H/logs/cost.csv" 24)
case "$NOTE" in
  "sub_usd:0.006000"|"sub_usd:0.006000;"*) ok ;;
  *) bad "A4 the note must START with sub_usd:0.006000: '$NOTE'" ;;
esac
RC=$(drive_ac COST_TRANSCRIPT_SUBAGENT_DIR=0)
eq "A4 knob 0: cost_usd = main only" "$(csvcol "$H/logs/cost.csv" 13)" 0.003000
case "$(csvcol "$H/logs/cost.csv" 24)" in
  "sub_usd:0.000000"|"sub_usd:0.000000;"*) ok ;;
  *) bad "A4 knob 0: the note must carry a measured zero: '$(csvcol "$H/logs/cost.csv" 24)'" ;;
esac

echo "--- R1. writer -> csv field -> digest reader"
if command -v cost_sub_usd_token >/dev/null 2>&1; then
  TOK=$(cost_sub_usd_token 0.123456)
  F=$(cost_csv_field "$TOK;price_v:3;acct=x")
  GOT=$(cd "$DIR/bin" && python3 -c 'import sys, dora_subagent; print(dora_subagent.parse_sub_usd(sys.argv[1]))' "$F" 2>&1)
  eq "R1 round trip" "$GOT" 0.123456
else
  bad "R1 cost_sub_usd_token is not defined"
fi

echo "cost-sub-usd.bh-10209: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

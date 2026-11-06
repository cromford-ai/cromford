#!/bin/bash
# tests/claude-cost-stdin-fp.bh-9064-test.sh — BH-9064 fix item 2: a prompt on
# stdin with no AGENT_CALL_FP gets a fingerprint computed from the argv AND the
# stdin text (K3's call_guard_fp of that sha), so bin/claude-cost.sh claims it
# (K3) and keys it in the dedup ledger. "K3 not claimed" no longer exists.
#   S1 a stdin prompt with no AGENT_CALL_FP writes 1 K3 claim
#   S2 two different stdin prompts with the same argv give two fps
#   S3 the same stdin prompt twice gives one fp, and the ledger row has
#      attempts=2 (this path never replays)
#   S4 the stdin bytes reach the fake claude unchanged
#   S5 no `K3 not claimed` line, and the temp file is gone after the call
#   S6 a ledger row failed at the cap is terminal: the stored rc, 0 calls,
#      the refusal on stderr, one LEDGER TERMINAL line, no paid K3 slot. The
#      cap is the larger of AGENT_LEDGER_MAX_ATTEMPTS and the K3 ceiling.
#   S7 the refute-review ladder: orchestrator=6, every rung fails rc 1 with
#      no transcript. Rungs 1-6 all run (the 4th is NOT refused by a ledger
#      cap of 3), and the 7th is K3's refusal, rc 74, not the ledger's.
#   S8 a failed call whose transcript shows 0 tokens settles `unbilled` and
#      gives the attempt back: 4 rate-limited rungs leave attempts=0, and a
#      5th rung still runs under AGENT_LEDGER_MAX_ATTEMPTS=3.
#
# Drives the real bin/claude-cost.sh with a fake claude on PATH and the REAL
# jobs worker (call-guard and agent-call-ledger routes) on a node:sqlite file
# (tests/lib/ledger-worker-fake.bh-9064.sh). No network, no vendor. Each case
# uses its own ticket id, so the cases do not depend on order.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/ledger-worker-fake.bh-9064.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
node -e 'require("node:sqlite")' 2>/dev/null || { echo "node:sqlite missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/flags" "$T/fakebin" "$T/home" "$T/tmp"
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$T/h" ) >/dev/null || { echo "FAIL: closure of bin/jobs-client.sh"; exit 1; }
lwf_install "$T/fakebin" "$T/jobs.db"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
# FAKE_TRANSCRIPT=zero: write the session transcript of a call that bought
# nothing (a quota / 429 answer: one assistant line with 0 tokens).
if [ "${FAKE_TRANSCRIPT:-}" = zero ]; then
  SID=""; prev=""
  for a in "$@"; do [ "$prev" = --session-id ] && SID="$a"; prev="$a"; done
  if [ -n "$SID" ]; then
    D="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(pwd -P | tr '/' '-')"; mkdir -p "$D"
    printf '{"type":"assistant","uuid":"u-%s","timestamp":"%s","message":{"id":"msg_%s","model":"test-model","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
      "$SID" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$SID" >> "$D/$SID.jsonl"
  fi
fi
cat > "$STDIN_SINK"
printf 'STDIN:%s\n' "$(cat "$STDIN_SINK")"
exit "${CLAUDE_RC:-0}"
EOF
chmod +x "$T/fakebin/"*

# cc <stdin-text> [VAR=VAL ...] -> prints the rc; stdout in $T/out, stderr in $T/err.
cc() {
  local text="$1"; shift
  printf '%s' "$text" | ( unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET HARNESS_TICKET
    cd "$T" && env PATH="$T/fakebin:$PATH" HOME="$T/home" HARNESS="$T/h" ORDER_SINK="$T/order" \
      STDIN_SINK="$T/stdin-seen" TMPDIR="$T/tmp" \
      JOBS_URL="https://jobs.test" HARNESS_SECRET="tok-fixture-bh9064" LWF_SECRET="tok-fixture-bh9064" \
      JOBS_RETRIES=0 JOBS_BOX=testbox COST_TRANSCRIPT_ROWS=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
      COST_STAGE=orchestrator COST_PROJECT=fleet CALL_GUARD_MAX_MAP="orchestrator=50" "$@" \
      bash "$DIR/bin/claude-cost.sh" -p > "$T/out" 2> "$T/err" )
  echo $?
}
calls() { grep -c . "$T/order" 2>/dev/null || true; }
claims() { lwf_sql "SELECT COUNT(*) AS n FROM call_guard WHERE stage='orchestrator' AND fp LIKE ?" "$1%" | jq -r .n; }
fps() { lwf_sql "SELECT DISTINCT fp FROM call_guard WHERE stage='orchestrator' AND fp LIKE ? ORDER BY fp" "$1%" | jq -r .fp; }
# want_fp <ticket> <stdin-text> — call_guard_fp of sha256(argv NUL-joined + stdin).
want_fp() {
  local psha
  psha=$( { printf '%s\0' -p; printf '%s' "$2"; } | sha256sum | cut -c1-64)
  ( cd "$T" && unset AGENT_CALL_FP HARNESS_TICKET; AGENT_CALL_TICKET="$1"; . "$DIR/bin/lib/call-guard.sh" && call_guard_fp "$psha" )
}
TK="BH-9164"

# --- S1 / S4 / S5. one stdin call is claimed --------------------------------
: > "$T/order"
r=$(cc "turn prompt one" AGENT_CALL_TICKET="${TK}a")
[ "$r" = 0 ] && [ "$(calls)" = 1 ] && ok || bad "S1a rc $r calls $(calls), want 0 1"
[ "$(claims "${TK}a:")" = 1 ] && ok || bad "S1b K3 claims: $(claims "${TK}a:"), want 1"
FP1=$(fps "${TK}a:")
[ "$FP1" = "$(want_fp "${TK}a" "turn prompt one")" ] && ok || bad "S1c fp '$FP1', want '$(want_fp "${TK}a" "turn prompt one")'"
[ "$(cat "$T/stdin-seen")" = "turn prompt one" ] && ok || bad "S4 the stdin bytes changed: '$(cat "$T/stdin-seen")'"
grep -qs 'K3 not claimed' "$T/h/logs/claude-cost.log" && bad "S5a 'K3 not claimed' was logged" || ok
[ -z "$(ls -A "$T/tmp" | grep claude-cost-stdin)" ] && ok || bad "S5b the stdin copy was left behind: $(ls "$T/tmp")"

# --- S2. a different stdin prompt is different work -------------------------
r=$(cc "turn prompt two" AGENT_CALL_TICKET="${TK}a")
[ "$(fps "${TK}a:" | grep -c .)" = 2 ] && ok || bad "S2 two stdin prompts gave $(fps "${TK}a:" | grep -c .) fps, want 2"

# --- S3. the same stdin prompt twice: one fp, attempts=2, no replay ---------
: > "$T/order"
r1=$(cc "turn prompt three" AGENT_CALL_TICKET="${TK}b")
r2=$(cc "turn prompt three" AGENT_CALL_TICKET="${TK}b")
[ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$(calls)" = 2 ] && ok || bad "S3a rcs $r1 $r2 calls $(calls), want 0 0 2"
[ "$(fps "${TK}b:" | grep -c .)" = 1 ] && ok || bad "S3b the same prompt gave $(fps "${TK}b:" | grep -c .) fps, want 1"
st=$(lwf_sql "SELECT status, attempts, answer_body FROM agent_call_ledger WHERE stage='orchestrator' AND fp=?" "$(fps "${TK}b:")" \
  | jq -r '"\(.status) \(.attempts) \(.answer_body)"')
[ "$st" = "ok 2 null" ] && ok || bad "S3c ledger row '$st', want 'ok 2 null' (recorded, no body kept)"

# --- S6. a ledger row failed at the cap is terminal -------------------------
: > "$T/order"; : > "$T/h/logs/agent-call-ledger.log"
FP6=$(want_fp "${TK}c" "turn prompt four")
# cc runs orchestrator=50 in K3, so the stage's cap is 50 (never below K3's).
lwf_sql "INSERT INTO agent_call_ledger (project,stage,fp,status,attempts,rc,first_at,last_at)
         VALUES ('fleet','orchestrator',?,'failed',50,1,strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now'))" "$FP6"
r=$(cc "turn prompt four" AGENT_CALL_TICKET="${TK}c")
[ "$r" = 1 ] && [ "$(calls)" = 0 ] && ok || bad "S6a failed attempts=50: rc $r calls $(calls), want 1 0"
grep -q '^AGENT_CALL_REFUSED call-guard repeat ledger-failed attempts=50 ' "$T/err" && ok || bad "S6b marker: $(cat "$T/err")"
[ "$(grep -c 'LEDGER TERMINAL failed' "$T/h/logs/agent-call-ledger.log")" = 1 ] && ok || bad "S6c LEDGER TERMINAL lines: $(cat "$T/h/logs/agent-call-ledger.log")"
paid=$(lwf_sql "SELECT COUNT(*) AS n FROM call_guard WHERE fp=? AND status IN ('claimed','ok','empty','failed')" "$FP6" | jq -r .n)
[ "$paid" = 0 ] && ok || bad "S6d the terminal call kept a paid K3 slot ($paid)"
[ -z "$(ls -A "$T/tmp" | grep claude-cost-stdin)" ] && ok || bad "S6e a refusal left the stdin copy behind: $(ls "$T/tmp")"

# --- S7. a 6-rung ladder of failures is never cut short by the ledger ------
: > "$T/order"; : > "$T/h/logs/agent-call-ledger.log"
rcs=""
for i in 1 2 3 4 5 6; do
  rcs="$rcs $(cc "turn prompt five" AGENT_CALL_TICKET="${TK}d" CALL_GUARD_MAX_MAP="orchestrator=6" CLAUDE_RC=1)"
done
[ "$rcs" = " 1 1 1 1 1 1" ] && [ "$(calls)" = 6 ] && ok || bad "S7a rungs 1-6: rcs '$rcs' calls $(calls), want 1 x6 and 6 calls"
grep -q 'LEDGER TERMINAL' "$T/h/logs/agent-call-ledger.log" && bad "S7b the ledger refused a rung K3 allowed: $(cat "$T/h/logs/agent-call-ledger.log")" || ok
r=$(cc "turn prompt five" AGENT_CALL_TICKET="${TK}d" CALL_GUARD_MAX_MAP="orchestrator=6" CLAUDE_RC=1)
[ "$r" = 74 ] && [ "$(calls)" = 6 ] && ok || bad "S7c rung 7: rc $r calls $(calls), want 74 (K3) and still 6"
grep -q '^AGENT_CALL_REFUSED call-guard repeat orchestrator ' "$T/err" && ok || bad "S7d rung 7 is not K3's refusal: $(cat "$T/err")"
st=$(lwf_sql "SELECT status, attempts FROM agent_call_ledger WHERE stage='orchestrator' AND fp=?" "$(want_fp "${TK}d" "turn prompt five")" \
  | jq -r '"\(.status) \(.attempts)"')
[ "$st" = "failed 6" ] && ok || bad "S7e ledger row '$st', want 'failed 6' (no transcript: counted as paid)"

# --- S8. a failed call that bought nothing gives the attempt back ----------
# K3 is off (CALL_GUARD=0: claude-cost's K3 settle counts every failure as
# paid) and its map gives orchestrator=1, so the ledger cap is the knob's 3.
: > "$T/order"
rcs=""
for i in 1 2 3 4 5; do
  rcs="$rcs $(cc "turn prompt six" AGENT_CALL_TICKET="${TK}e" \
    AGENT_LEDGER_MAX_ATTEMPTS=3 CALL_GUARD_MAX_MAP="orchestrator=1" COST_TRANSCRIPT_ROWS=1 FAKE_TRANSCRIPT=zero CLAUDE_RC=1 CALL_GUARD=0)"
done
[ "$rcs" = " 1 1 1 1 1" ] && [ "$(calls)" = 5 ] && ok || bad "S8a 5 rate-limited rungs: rcs '$rcs' calls $(calls), want 1 x5 and 5 calls"
st=$(lwf_sql "SELECT status, attempts FROM agent_call_ledger WHERE stage='orchestrator' AND fp=?" "$(want_fp "${TK}e" "turn prompt six")" \
  | jq -r '"\(.status) \(.attempts)"')
[ "$st" = "unbilled 0" ] && ok || bad "S8b ledger row '$st', want 'unbilled 0' (0 tokens in the transcript: nothing bought)"

echo "claude-cost-stdin-fp.bh-9064: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

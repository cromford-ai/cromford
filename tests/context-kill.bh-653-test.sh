#!/bin/bash
# tests/context-kill.bh-653-test.sh — the CUMULATIVE CONTEXT KILL in
# bin/agent-call.sh, driven for real (BH-653).
#
# WHY DRIVEN AND NOT GREPPED. Both bounds this replaces are recorded in
# catalog/context-budgets.json as INERT: `grok --max-turns` was measured running
# 56 tool calls against a cap of 25, and `--max-budget-usd` let a $4.67 turn
# complete against a $2.00 cap. Both READ as enforcement. A guard whose only
# evidence is `grep -q context_meter bin/agent-call.sh` would read exactly the
# same way, which is why every assertion below is about an ARTIFACT: the child
# pid, $OUT, $OUT.ctxkill, logs/ALERTS.log, logs/failovers.log, logs/cost.csv.
#
# HOW. agent-call.sh runs against a scratch $HARNESS with a fake `claude` on
# PATH. The fake reads its own --session-id off argv and writes real-shaped
# assistant entries into a session transcript under $HOME/.claude/projects, one
# every 0.2s, so the meter reads a session that is genuinely growing while the
# child runs — the same file bin/transcript-cost.sh reads in production.
# STUB_ENTRIES picks how far it grows: 40 x 5,000 input tokens = 200K, past the
# fixture lane's 100,000 ceiling; 10 = 50K, under it.
#
# WHAT THIS DOES NOT PROVE: that the ceilings chosen for alert-triage and
# responder are the right numbers. That is a judgement about live traffic, and
# it stays PENDING in the manifest until the first real CONTEXT KILL line. Nor
# does it exercise GNU timeout's own TERM forwarding — the fixture's `timeout`
# execs its command directly, so the meter's TERM reaches the stub with no
# process layer between.
# Run from anywhere: tests/context-kill.bh-653-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-9536: the meter default is alert; this suite pins the kill mode
export CONTEXT_KILL_MODE=kill
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date -u '+%Y%m%d')
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/.claude/projects/-work"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- the fixture manifest -----------------------------------------------------
# kill-lane carries an explicit context_kill_tokens; free-lane deliberately does
# not, which is the "a lane with no number is unbounded exactly as today" case.
cat > "$T/budgets.json" <<'EOF'
{
  "_units": "input_toks + cache_read",
  "lanes": [
    {"lane":"kill-lane","stage":"eval","project":"testproj","ceiling_tokens":200000,
     "target_tokens":1000,"context_kill_tokens":100000,"composition":[],
     "bounds":["[lane:context_kill] test fixture PENDING"]},
    {"lane":"free-lane","stage":"eval","project":"freeproj","ceiling_tokens":200000,
     "target_tokens":1000,"composition":[],"bounds":["[lane:none] none, by design PENDING"]}
  ]
}
EOF

# --- the fake claude ----------------------------------------------------------
# Writes $$ so the test can ask whether the child really died, then grows a real
# transcript, then answers like the CLI's json envelope.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
echo $$ > "$T_DIR/child.pid"
PROJ="${STUB_TRANSCRIPT_DIR:-$HOME/.claude/projects/-work}"
mkdir -p "$PROJ"
n=0
while [ "$n" -lt "${STUB_ENTRIES:-10}" ]; do
  n=$((n+1))
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-09-17T18:00:00Z","message":{"id":"msg_%s","model":"claude-fable-5-1","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" >> "$PROJ/$sid.jsonl"
  sleep 0.2
done
printf '{"result":"CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
chmod +x "$T/fakebin/claude"
cp "$T/fakebin/claude" "$T/claude.plain"

# A fake claude that CATCHES the TERM, answers anyway and exits 0 — the CLI
# behaviour that would otherwise let a killed session report success.
cat > "$T/fakebin/claude-trapper" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
echo $$ > "$T_DIR/child.pid"
trap 'printf "{\"result\":\"PARTIAL\",\"usage\":{\"input_tokens\":50,\"output_tokens\":10},\"session_id\":\"$sid\",\"total_cost_usd\":0.01}\n"; exit 0' TERM
PROJ="${STUB_TRANSCRIPT_DIR:-$HOME/.claude/projects/-work}"
mkdir -p "$PROJ"
n=0
while [ "$n" -lt "${STUB_ENTRIES:-10}" ]; do
  n=$((n+1))
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-09-17T18:00:00Z","message":{"id":"msg_%s","model":"claude-fable-5-1","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" >> "$PROJ/$sid.jsonl"
  sleep 0.2
done
printf '{"result":"CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
chmod +x "$T/fakebin/claude-trapper"

# The tier-2 vendor lane must never engage on a context kill: if grok runs, it
# leaves a file behind and section 7 says so.
mkdir -p "$T/.grok/bin"
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
touch "$T_DIR/grok-was-called"
echo "GROK ANSWER"
EOF
chmod +x "$T/fakebin/grok"; cp "$T/fakebin/grok" "$T/.grok/bin/grok"

# GNU timeout is shimmed for the same reason the other agent-call suites shim
# it (macOS has none), and because the real one would add a process layer
# between the meter's TERM and the stub.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"; chmod +x "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

# --- the driver ---------------------------------------------------------------
run_call() { # run_call <outfile> <project> [env assignments...] ; echoes the rc
  local out="$1" proj="$2"; shift 2
  rm -f "$out" "$out.json" "$out.err" "$out.ctxkill" "$T/child.pid" "$T/grok-was-called"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$T/budgets.json" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 LADDER_TIER2_GROK=1
    # A build session exports its own ticket; left set, this suite's two kill
    # rows name it and the repeat stop (BH-2538) refuses every later section.
    unset AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET
    env "$@" bash "$DIR/bin/agent-call.sh" eval "$proj" claude-fable-5-1 60 "$out" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
child_alive() { # child_alive -> 0 when the stub is still running
  local p; p=$(cat "$T/child.pid" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# =============================================================================
# 1. THE KILL. 40 entries x 5,000 = 200K against a 100,000 ceiling.
# =============================================================================
: > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; : > "$T/logs/cost.csv"
RC1=$(run_call "$T/out.kill" testproj STUB_ENTRIES=40 XAI_API_KEY=x)
[ "$RC1" != 0 ] \
  && ok || bad "1: a killed session reported rc=0 — every caller would treat a truncated answer as a finished one"
child_alive \
  && bad "1: the child is still running after agent-call returned — the meter never killed it (pid $(cat "$T/child.pid" 2>/dev/null))" || ok
[ -f "$T/out.kill.ctxkill" ] \
  && ok || bad "1: no \$OUT.ctxkill marker file — nothing recorded that the ceiling was crossed"
CK=$(cat "$T/out.kill.ctxkill" 2>/dev/null)
grep -q 'ceiling=100000' <<<"$CK" \
  && ok || bad "1: the kill record does not name the ceiling it fired on: ${CK:-<empty>}"
KTOT=$(sed -n 's/.*total=\([0-9]*\).*/\1/p' <<<"$CK")
[ -n "$KTOT" ] && [ "$KTOT" -gt 100000 ] \
  && ok || bad "1: the kill record's total ($KTOT) is not above the ceiling — the meter is not summing input+cache_read"
KCALLS=$(sed -n 's/.*calls=\([0-9]*\).*/\1/p' <<<"$CK")
[ -n "$KCALLS" ] && [ "$KCALLS" -ge 20 ] \
  && ok || bad "1: the kill record's API call count ($KCALLS) is below the 20 responses 100K of context takes"
KSID=$(sed -n 's/.*session=\([0-9a-f-]*\).*/\1/p' <<<"$CK")
[ -n "$KSID" ] && [ -s "$T/.claude/projects/-work/$KSID.jsonl" ] \
  && ok || bad "1: the kill record names no session that has a transcript (session=$KSID)"
# ...and it fired EARLY. THE DISCRIMINATING ASSERTION: "the child is gone
# afterwards" is true of a session that simply finished, so without this the
# whole kill could be a coincidence — verified by deleting the meter's
# `kill -TERM` and watching only this line go red.
ENTRIES=$(grep -c '"usage"' "$T/.claude/projects/-work/$KSID.jsonl" 2>/dev/null)
[ -n "$ENTRIES" ] && [ "$ENTRIES" -lt 40 ] \
  && ok || bad "1: the stub wrote all 40 entries ($ENTRIES) — it ran to completion and was never terminated"

# =============================================================================
# 2. THE TRUNCATION MARKER — what the caller reads (alert-triage.sh tails $OUT).
# =============================================================================
tail -1 "$T/out.kill" 2>/dev/null | grep -q '^CONTEXT KILL: eval/testproj' \
  && ok || bad "2: \$OUT's last line is not the truncation marker — a cut session is indistinguishable from a clean one: $(tail -1 "$T/out.kill" 2>/dev/null)"
tail -1 "$T/out.kill" 2>/dev/null | grep -q 'TRUNCATED' \
  && ok || bad "2: the marker does not say the output is truncated"

# =============================================================================
# 3. EXACTLY ONE lane alert, carrying lane, ceiling and call count.
# =============================================================================
NAL=$(grep -c 'CONTEXT KILL' "$T/logs/ALERTS.log" 2>/dev/null)
[ "$NAL" = 1 ] \
  && ok || bad "3: expected exactly one CONTEXT KILL line in ALERTS.log, found $NAL"
AL=$(grep 'CONTEXT KILL' "$T/logs/ALERTS.log" 2>/dev/null | head -1)
grep -q 'eval/testproj' <<<"$AL" \
  && ok || bad "3: the alert does not name the lane: $AL"
grep -q 'ceiling 100000' <<<"$AL" \
  && ok || bad "3: the alert does not name the ceiling: $AL"
grep -qE 'after [0-9]+ API calls' <<<"$AL" \
  && ok || bad "3: the alert does not carry the API call count: $AL"
{ [ -n "$KSID" ] && grep -q "$KSID" <<<"$AL"; } \
  && ok || bad "3: the alert does not name the session: $AL"
[ "$(grep -c 'BUDGET STOP' "$T/logs/ALERTS.log" 2>/dev/null)" = 0 ] \
  && ok || bad "3: a second, less specific BUDGET STOP line was written for the same event"
[ "$(grep -c 'BUDGET FLAG INERT' "$T/logs/ALERTS.log" 2>/dev/null)" = 0 ] \
  && ok || bad "3: a run WE cut short was reported as evidence the vendor's budget flag is inert"

# =============================================================================
# 7. NO RE-SPEND. A policy stop: no opus escalation, no same-lane retry, no
#    tier-2 grok, no survival lane.
# =============================================================================
FO=$(cat "$T/logs/failovers.log" 2>/dev/null)
grep -q 'retrying as claude-opus-5' <<<"$FO" \
  && bad "7: the killed session was re-bought on opus" || ok
grep -q 'one retry on the SAME lane' <<<"$FO" \
  && bad "7: the kill was classified as an EXTERNAL kill and retried — that re-spends the context we just stopped" || ok
grep -q 'tier-2' <<<"$FO$(cat "$T/logs/ALERTS.log")" \
  && bad "7: the tier-2 grok lane engaged on a context kill" || ok
[ -f "$T/grok-was-called" ] \
  && bad "7: grok actually ran after a context kill — the whole context was re-bought on another vendor" || ok
grep -q 'lane context ceiling' <<<"$FO" \
  && ok || bad "7: the policy stop left no record in failovers.log, where the rest of the ladder's decisions are"

# =============================================================================
# 9. THE COST ROW still prices the killed session from its own transcript,
#    and says killed (BH-3990).
# =============================================================================
ROW=$(grep ',eval,claude,' "$T/logs/cost.csv" 2>/dev/null | tail -1)
[ -n "$ROW" ] \
  && ok || bad "9: no cost row for the killed call — a kill must still bill what it spent"
RCF=$(cut -d, -f7 <<<"$ROW"); SRC=$(cut -d, -f18 <<<"$ROW"); INF=$(cut -d, -f9 <<<"$ROW")
{ [ "$RCF" = 143 ] || [ "$RCF" = 137 ]; } \
  && ok || bad "9: the cost row's rc is '$RCF', not the kill's: $ROW"
# BH-3990: a killed row says so in row_source; its tokens are still the
# transcript's (the input_toks assertion below).
[ "$SRC" = killed ] \
  && ok || bad "9: the killed session's row_source is '$SRC', want killed (BH-3990): $ROW"
[ -n "$INF" ] && [ "$INF" -gt 0 ] \
  && ok || bad "9: the killed session's row carries no input tokens: $ROW"

# =============================================================================
# 2b. The CLI catches TERM and exits 0 with an envelope. Still marked, still
#     nonzero: the marker file is authoritative, not the rc.
# =============================================================================
cp "$T/fakebin/claude-trapper" "$T/fakebin/claude"
: > "$T/logs/ALERTS.log"
RC2B=$(run_call "$T/out.trap" testproj STUB_ENTRIES=40)
[ "$RC2B" != 0 ] \
  && ok || bad "2b: a CLI that swallowed the TERM and exited 0 turned a killed session into a success (rc=$RC2B)"
tail -1 "$T/out.trap" 2>/dev/null | grep -q '^CONTEXT KILL: eval/testproj' \
  && ok || bad "2b: no truncation marker when the CLI answered anyway: $(tail -1 "$T/out.trap" 2>/dev/null)"
grep -q 'PARTIAL' "$T/out.trap" 2>/dev/null \
  && ok || bad "2b: the CLI's own partial answer was lost — the marker must be APPENDED to what it did produce"
# restore the plain stub for the remaining sections
cp "$T/claude.plain" "$T/fakebin/claude"

# =============================================================================
# 4. UNDER THE CEILING: untouched, and byte-identical to the switch-off path.
# =============================================================================
: > "$T/logs/ALERTS.log"
RC4=$(run_call "$T/out.a" testproj STUB_ENTRIES=10)
[ "$RC4" = 0 ] \
  && ok || bad "4: a session that stayed under its ceiling failed (rc=$RC4)"
[ "$(cat "$T/out.a" 2>/dev/null)" = "CLEAN DONE" ] \
  && ok || bad "4: an under-ceiling session's output was altered: $(cat "$T/out.a" 2>/dev/null)"
[ ! -f "$T/out.a.ctxkill" ] \
  && ok || bad "4: a .ctxkill marker was written for a session that never crossed its ceiling"
[ "$(grep -c 'CONTEXT KILL' "$T/logs/ALERTS.log" 2>/dev/null)" = 0 ] \
  && ok || bad "4: an under-ceiling session produced a CONTEXT KILL alert"
RC4B=$(run_call "$T/out.b" testproj STUB_ENTRIES=10 CONTEXT_KILL=0)
cmp -s "$T/out.a" "$T/out.b" \
  && ok || bad "4: metered-but-under-ceiling output differs from the unmetered path — the meter changed the answer"
jq -S 'del(.session_id)' "$T/out.a.json" > "$T/a.norm" 2>/dev/null
jq -S 'del(.session_id)' "$T/out.b.json" > "$T/b.norm" 2>/dev/null
cmp -s "$T/a.norm" "$T/b.norm" \
  && ok || bad "4: the CLI envelope differs between the metered and unmetered paths — every reader of \$OUT.json is affected"

# =============================================================================
# 5. THE KILL SWITCH, both forms, with the ceiling still configured.
# =============================================================================
touch "$T/flags/context-kill-off"
: > "$T/logs/ALERTS.log"
RC5=$(run_call "$T/out.flag" testproj STUB_ENTRIES=40)
[ "$RC5" = 0 ] \
  && ok || bad "5: flags/context-kill-off did not restore the old behaviour (rc=$RC5)"
[ ! -f "$T/out.flag.ctxkill" ] && [ "$(grep -c 'CONTEXT KILL' "$T/logs/ALERTS.log")" = 0 ] \
  && ok || bad "5: the kill fired with flags/context-kill-off in place"
[ "$(cat "$T/out.flag" 2>/dev/null)" = "CLEAN DONE" ] \
  && ok || bad "5: the flagged-off run did not complete: $(cat "$T/out.flag" 2>/dev/null)"
rm -f "$T/flags/context-kill-off"
: > "$T/logs/ALERTS.log"
RC5B=$(run_call "$T/out.off" testproj STUB_ENTRIES=40 CONTEXT_KILL=0)
[ "$RC5B" = 0 ] && [ ! -f "$T/out.off.ctxkill" ] && [ "$(cat "$T/out.off" 2>/dev/null)" = "CLEAN DONE" ] \
  && ok || bad "5: CONTEXT_KILL=0 did not restore the old behaviour (rc=$RC5B, out=$(cat "$T/out.off" 2>/dev/null))"

# =============================================================================
# 6. A LANE WITH NO CEILING is unbounded, exactly as today.
# =============================================================================
: > "$T/logs/ALERTS.log"
RC6=$(run_call "$T/out.free" freeproj STUB_ENTRIES=40)
[ "$RC6" = 0 ] \
  && ok || bad "6: a lane with no context_kill_tokens was killed anyway (rc=$RC6)"
[ ! -f "$T/out.free.ctxkill" ] && [ "$(grep -c 'CONTEXT KILL' "$T/logs/ALERTS.log")" = 0 ] \
  && ok || bad "6: a lane with no declared ceiling produced a kill"
[ "$(cat "$T/out.free" 2>/dev/null)" = "CLEAN DONE" ] \
  && ok || bad "6: the unbounded lane's session did not complete: $(cat "$T/out.free" 2>/dev/null)"

# =============================================================================
# 8. A FAILED READ IS NOT A KILL. The transcript is written somewhere the
#    helper cannot find it: the meter must keep the work alive and say so once.
#    Fail-open toward the running session is the direction that matters — a
#    meter that kills on a read failure is worse than no meter.
# =============================================================================
: > "$T/logs/ALERTS.log"; : > "$T/logs/claude-cost.log"
RC8=$(run_call "$T/out.blind" testproj STUB_ENTRIES=40 STUB_TRANSCRIPT_DIR="$T/elsewhere/-work")
[ "$RC8" = 0 ] \
  && ok || bad "8: an unreadable transcript killed a healthy session (rc=$RC8)"
[ ! -f "$T/out.blind.ctxkill" ] \
  && ok || bad "8: a failed meter read was treated as a ceiling crossing"
[ "$(grep -c 'context meter' "$T/logs/claude-cost.log" 2>/dev/null)" = 1 ] \
  && ok || bad "8: expected exactly one 'context meter' line about the unreadable session, found $(grep -c 'context meter' "$T/logs/claude-cost.log" 2>/dev/null)"

# =============================================================================
# 10. DECLARED BUT UNENFORCEABLE. COST_TRANSCRIPT_ROWS=0 mints no session id, so
#     there is no transcript to meter — the lane's ceiling is in the manifest
#     and cannot fire. That has to be SAID (CLAUDE.md: "stopping is an alert,
#     not a whisper"), once per stage per day, and it must not turn into a kill
#     or into a failure of the run itself.
# =============================================================================
: > "$T/logs/ALERTS.log"
rm -f "$T/flags/alerted-ctxkill-unenforceable-eval-$NOW"
RC10=$(run_call "$T/out.norows" testproj STUB_ENTRIES=40 COST_TRANSCRIPT_ROWS=0)
[ "$RC10" = 0 ] \
  && ok || bad "10: a lane whose ceiling cannot be enforced failed the run instead of running unbounded (rc=$RC10)"
[ ! -f "$T/out.norows.ctxkill" ] \
  && ok || bad "10: a kill fired with no session to meter"
[ "$(cat "$T/out.norows" 2>/dev/null)" = "CLEAN DONE" ] \
  && ok || bad "10: the unmeterable session did not complete: $(cat "$T/out.norows" 2>/dev/null)"
NU=$(grep -c 'CONTEXT KILL UNENFORCEABLE' "$T/logs/ALERTS.log" 2>/dev/null)
[ "$NU" = 1 ] \
  && ok || bad "10: expected exactly one CONTEXT KILL UNENFORCEABLE line, found $NU — a ceiling the manifest declares and the box cannot enforce is silent"
UL=$(grep 'CONTEXT KILL UNENFORCEABLE' "$T/logs/ALERTS.log" 2>/dev/null | head -1)
grep -q 'COST_TRANSCRIPT_ROWS' <<<"$UL" \
  && ok || bad "10: the unenforceable alert does not name the reason an operator can act on: $UL"
grep -q 'eval/testproj' <<<"$UL" \
  && ok || bad "10: the unenforceable alert does not name the lane: $UL"
RC10B=$(run_call "$T/out.norows2" testproj STUB_ENTRIES=10 COST_TRANSCRIPT_ROWS=0)
[ "$RC10B" = 0 ] && [ "$(grep -c 'CONTEXT KILL UNENFORCEABLE' "$T/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "10: the unenforceable alert repeated on the same day — every call of a busy lane would page (rc=$RC10B)"

echo "context-kill.bh-653-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

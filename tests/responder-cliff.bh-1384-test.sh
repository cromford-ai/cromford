#!/bin/bash
# tests/responder-cliff.bh-1384-test.sh — the session ceiling derived from the
# model's PRICE CLIFF, and the watchdog responder's two knobs that drive it
# (BH-1384).
#
# WHY DRIVEN AND NOT GREPPED. The thing under test decides whether to KILL a
# paid session, which is irreversible and operator-visible, and the four
# mechanisms it rides on (the lane ceiling, the marker file, the alert line, the
# cooldown stamp) are all artifacts. So every assertion below is about an
# artifact — $OUT.ctxkill, $OUT.cliffcap, logs/ALERTS.log, logs/failovers.log,
# logs/responder.log, state/responder/handled.json, logs/cost.csv, the recorded
# environment of the child — and never about the source text of a script.
#
# HOW. Section A runs the real bin/agent-call.sh against a scratch $HARNESS with
# the tests/context-kill.bh-653-test.sh fixture: a fake `claude` that grows a
# real session transcript under $HOME/.claude/projects (STUB_ENTRIES x 5,000
# input tokens), a fake `timeout` that execs directly, a budgets.json with the
# lanes, and a MODEL_PRICES fixture where one model carries cliff_tokens and the
# others carry none / null / a string / no entry at all. Sections B and C run
# the real bin/watchdog-responder.sh with only its harness ROOT rewritten (the
# precedent in tests/responder-prefetch-test.sh); B records what the agent call
# RECEIVES, C puts the real bin/agent-call.sh behind it.
#
# WHAT THIS SUITE DOES NOT PROVE: that any model the responder actually runs on
# has a cliff. In today's catalog/model-prices.json only grok-4.6 carries
# cliff_tokens and the metered rung is claude, so the cliff path is DORMANT in
# production — the operative responder ceiling is the settings row (B1). That is
# a fact about the price table, not about this code, and the fixture says so by
# giving its own models the key.
# Run from anywhere: tests/responder-cliff.bh-1384-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" \
         "$T/.claude/projects/-work"

# =============================================================================
# SECTION A — bin/agent-call.sh, driven for real
# =============================================================================

# kill-lane carries a 6,000,000 ceiling (the responder's real number, so the
# CLIFF is what lowers it); cap-lane carries 120,000 (below cliff-minus-margin,
# so the LANE cap is what lowers it); free-lane has no key at all.
cat > "$T/budgets.json" <<'EOF'
{
  "_units": "input_toks + cache_read",
  "lanes": [
    {"lane":"kill-lane","stage":"eval","project":"testproj","ceiling_tokens":6000000,
     "target_tokens":1000,"context_kill_tokens":6000000,"composition":[],
     "bounds":["[lane:context_kill] test fixture PENDING"]},
    {"lane":"cap-lane","stage":"eval","project":"caplow","ceiling_tokens":200000,
     "target_tokens":1000,"context_kill_tokens":120000,"composition":[],
     "bounds":["[lane:context_kill] test fixture PENDING"]},
    {"lane":"free-lane","stage":"eval","project":"freeproj","ceiling_tokens":200000,
     "target_tokens":1000,"composition":[],"bounds":["[lane:none] none, by design PENDING"]}
  ]
}
EOF

# The price fixture. cliff-fixture-1 is the only model with a usable cliff; the
# other four are the adversarial negatives (c)1-4 of the plan, in the table
# itself rather than asserted in prose.
cat > "$T/prices.json" <<'EOF'
{
  "cliff-fixture-1":   {"prompt":0.000001,"completion":0.000002,"cache_read":0,"cache_write":0,"cliff_tokens":200000},
  "nocliff-fixture":   {"prompt":0.000001,"completion":0.000002,"cache_read":0,"cache_write":0},
  "nullcliff-fixture": {"prompt":0.000001,"completion":0.000002,"cache_read":0,"cache_write":0,"cliff_tokens":null},
  "strcliff-fixture":  {"prompt":0.000001,"completion":0.000002,"cache_read":0,"cache_write":0,"cliff_tokens":"200000"},
  "claude-fable-5-1":  {"prompt":0.000001,"completion":0.000002,"cache_read":0,"cache_write":0,"cliff_tokens":200000},
  "claude-opus-5":     {"prompt":0.00001,"completion":0.00002,"cache_read":0,"cache_write":0}
}
EOF

# The fake claude: records the ceiling variables it INHERITED (they must not
# leak into the session this call starts), writes $$ so the test can ask whether
# the child really died, grows a real transcript, then answers like the CLI.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""; mdl=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; --model) mdl="$a" ;; esac
  prev="$a"
done
printf '%s %s %s\n' "${CONTEXT_KILL_TOKENS:-unset}" "${CONTEXT_KILL_CLIFF:-unset}" \
  "${CONTEXT_KILL_CLIFF_MARGIN:-unset}" > "$T_DIR/envsink"
echo "$mdl" >> "$T_DIR/models-called"
echo $$ > "$T_DIR/child.pid"
[ -n "${STUB_FAIL_MODEL:-}" ] && [ "$mdl" = "$STUB_FAIL_MODEL" ] && { echo "stub refusing $mdl" >&2; exit 1; }
PROJ="${STUB_TRANSCRIPT_DIR:-$HOME/.claude/projects/-work}"
mkdir -p "$PROJ"
n=0
while [ "$n" -lt "${STUB_ENTRIES:-10}" ]; do
  n=$((n+1))
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-09-17T18:00:00Z","message":{"id":"msg_%s","model":"%s","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" "$mdl" >> "$PROJ/$sid.jsonl"
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
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"; chmod +x "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

# THE LADDER IS PINNED, NOT INHERITED. agent-call.sh walks claude.ladder from
# model_routes: on a box whose env dir holds HARNESS_SECRET the live worker
# answers, and in the gate's `env -i` snapshot nothing does, so the ladder was
# fable alone there and A5 could never reach a second rung. HARNESS_ENV_DIR
# points at an empty dir (no secret = the worker is never asked) and the
# resolver's box cache carries the one ladder this section needs.
mkdir -p "$T/noenv" "$T/state/model-routes"
for key in claude.ladder claude.ladder@testproj claude.ladder@caplow claude.ladder@freeproj; do
  printf '0\tclaude-fable-5-1\tclaude\n1\tclaude-opus-5\tclaude\n' > "$T/state/model-routes/$key.tsv"
done
run_call() { # run_call <outfile> <project> <model> [env assignments...] ; echoes the rc
  local out="$1" proj="$2" mdl="$3"; shift 3
  rm -f "$out" "$out.json" "$out.err" "$out.ctxkill" "$out.cliffcap" \
        "$T/child.pid" "$T/envsink" "$T/models-called"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$T/budgets.json" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 MODEL_PRICES="$T/prices.json" HARNESS_ENV_DIR="$T/noenv"
    unset HARNESS_SECRET JOBS_URL
    # A build session exports its own ticket; left set, this suite's kill rows
    # name it and the repeat stop (BH-2538) refuses the later sections.
    unset AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET
    env "$@" bash "$DIR/bin/agent-call.sh" eval "$proj" "$mdl" 60 "$out" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
child_alive() {
  local p; p=$(cat "$T/child.pid" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# --- A1: the cliff lowers the ceiling ----------------------------------------
: > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; : > "$T/logs/cost.csv"
# 60 entries = 300,000 tokens: the ceiling has to be crossed with the session
# still running, not on its last transcript line, or the assertion would be
# about the meter's poll interval rather than about the ceiling.
RC1=$(run_call "$T/out.a1" testproj cliff-fixture-1 STUB_ENTRIES=60 \
        CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000)
[ "$RC1" != 0 ] \
  && ok || bad "A1: a session stopped at the cliff ceiling reported rc=0"
child_alive \
  && bad "A1: the child is still running — the ceiling was never enforced" || ok
CK1=$(cat "$T/out.a1.ctxkill" 2>/dev/null)
grep -q 'ceiling=190000' <<<"$CK1" \
  && ok || bad "A1: the kill record does not carry the cliff-derived ceiling 190000: ${CK1:-<none>}"
KT1=$(sed -n 's/.*total=\([0-9]*\).*/\1/p' <<<"$CK1")
{ [ -n "$KT1" ] && [ "$KT1" -gt 190000 ] && [ "$KT1" -lt 6000000 ]; } \
  && ok || bad "A1: the session was stopped at total=$KT1, not between the cliff ceiling and the lane cap"
[ -f "$T/out.a1.cliffcap" ] \
  && ok || bad "A1: no \$OUT.cliffcap marker — nothing records that the cliff is what lowered the ceiling"
CC1=$(cat "$T/out.a1.cliffcap" 2>/dev/null)
[ "$CC1" = "cliff=200000 ceiling=190000 model=cliff-fixture-1 margin=10000" ] \
  && ok || bad "A1: the cliff marker does not read 'cliff=200000 ceiling=190000 model=cliff-fixture-1 margin=10000': ${CC1:-<none>}"

# --- A6 (first half): the alert says CLIFF-AVOIDED, never CONTEXT KILL -------
NC1=$(grep -c 'CLIFF-AVOIDED:' "$T/logs/ALERTS.log" 2>/dev/null)
NK1=$(grep -c 'CONTEXT KILL:' "$T/logs/ALERTS.log" 2>/dev/null)
{ [ "$NC1" = 1 ] && [ "$NK1" = 0 ]; } \
  && ok || bad "A6: expected exactly one CLIFF-AVOIDED: and zero CONTEXT KILL: lines in ALERTS.log, found $NC1 / $NK1"
AL1=$(grep 'CLIFF-AVOIDED:' "$T/logs/ALERTS.log" 2>/dev/null | head -1)
grep -q '200000' <<<"$AL1" \
  && ok || bad "A6: the CLIFF-AVOIDED alert does not name the cliff it avoided: $AL1"
grep -q 'cliff-fixture-1' <<<"$AL1" \
  && ok || bad "A6: the CLIFF-AVOIDED alert does not name the model: $AL1"
grep -q 'CLIFF-AVOIDED' "$T/logs/failovers.log" 2>/dev/null \
  && ok || bad "A6: the ladder's own record in failovers.log does not carry the CLIFF-AVOIDED label"

# --- A8: the killed session still writes its cost row ------------------------
ROW=$(grep ',eval,claude,' "$T/logs/cost.csv" 2>/dev/null | tail -1)
[ -n "$ROW" ] \
  && ok || bad "A8: no cost row for the stopped call — a stop must still bill what it spent"
SRC=$(cut -d, -f18 <<<"$ROW"); INF=$(cut -d, -f9 <<<"$ROW")
# BH-3990: a stopped session's row says killed, and keeps its transcript tokens.
[ "$SRC" = killed ] && [ -n "$INF" ] && [ "$INF" -gt 0 ] \
  && ok || bad "A8: the stopped session's row is not killed with its transcript tokens (row_source=$SRC input=$INF): $ROW"

# --- A2: a model with no cliff is unchanged ----------------------------------
: > "$T/logs/ALERTS.log"
RC2=$(run_call "$T/out.a2" testproj nocliff-fixture STUB_ENTRIES=10 \
        CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000)
[ "$RC2" = 0 ] \
  && ok || bad "A2: a model with no cliff was stopped anyway (rc=$RC2)"
[ ! -f "$T/out.a2.ctxkill" ] && [ ! -f "$T/out.a2.cliffcap" ] \
  && ok || bad "A2: a model with no cliff_tokens produced a kill or a cliff marker"
[ "$(cat "$T/out.a2" 2>/dev/null)" = "CLEAN DONE" ] \
  && ok || bad "A2: the no-cliff session's output was altered: $(cat "$T/out.a2" 2>/dev/null)"

# --- A3: a margin larger than the cliff floors at 1000 and SAYS so -----------
: > "$T/logs/failovers.log"
RC3=$(run_call "$T/out.a3" testproj cliff-fixture-1 STUB_ENTRIES=40 \
        CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=250000)
[ "$RC3" != 0 ] \
  && ok || bad "A3: the floored ceiling never fired (rc=$RC3)"
grep -q 'ceiling=1000 ' "$T/out.a3.cliffcap" 2>/dev/null \
  && ok || bad "A3: the floored ceiling is not 1000: $(cat "$T/out.a3.cliffcap" 2>/dev/null)"
FL3=$(grep -i 'floor' "$T/logs/failovers.log" 2>/dev/null | head -1)
[ -n "$FL3" ] \
  && ok || bad "A3: the floor was applied silently — nothing in failovers.log says the margin was bigger than the cliff"
{ grep -q '250000' <<<"$FL3" && grep -q '200000' <<<"$FL3" && grep -q '1000' <<<"$FL3"; } \
  && ok || bad "A3: the floor line does not name the cliff, the margin and the floor: $FL3"

# --- A4: the lane cap already below the cliff wins, and is labelled as such --
: > "$T/logs/ALERTS.log"
RC4=$(run_call "$T/out.a4" caplow cliff-fixture-1 STUB_ENTRIES=40 \
        CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000)
[ "$RC4" != 0 ] \
  && ok || bad "A4: the lane cap never fired (rc=$RC4)"
grep -q 'ceiling=120000' "$T/out.a4.ctxkill" 2>/dev/null \
  && ok || bad "A4: the ceiling is not the lane's 120000: $(cat "$T/out.a4.ctxkill" 2>/dev/null)"
[ ! -f "$T/out.a4.cliffcap" ] \
  && ok || bad "A4: a lane-cap kill was marked as cliff-derived — the CLIFF-AVOIDED copy would be false"
NC4=$(grep -c 'CLIFF-AVOIDED:' "$T/logs/ALERTS.log" 2>/dev/null)
NK4=$(grep -c 'CONTEXT KILL:' "$T/logs/ALERTS.log" 2>/dev/null)
{ [ "$NK4" = 1 ] && [ "$NC4" = 0 ]; } \
  && ok || bad "A4/A6: a lane-cap kill must alert as CONTEXT KILL: exactly once and never as CLIFF-AVOIDED: (found $NK4 / $NC4)"

# --- A5: the marker never outlives the attempt that wrote it -----------------
# CONTROL: the fable rung alone, succeeding, DOES leave a cliff marker. Without
# this, the absence asserted below could mean the marker was never written.
RC5C=$(run_call "$T/out.a5c" testproj claude-fable-5-1 STUB_ENTRIES=2 \
        CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000)
grep -q 'model=claude-fable-5-1' "$T/out.a5c.cliffcap" 2>/dev/null \
  && ok || bad "A5 control: the fable rung wrote no cliff marker (rc=$RC5C), so A5 would prove nothing"
# The fable rung has a cliff and FAILS (rc 1); the ladder escalates to opus,
# which has none. After the run there must be no cliff marker left to label the
# opus attempt with the fable attempt's ceiling.
RC5=$(run_call "$T/out.a5" testproj claude-fable-5-1 STUB_ENTRIES=2 \
        CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000 STUB_FAIL_MODEL=claude-fable-5-1)
grep -q 'claude-opus-5' "$T/models-called" 2>/dev/null \
  && ok || bad "A5: the ladder never reached a second rung, so nothing was proven about a stale marker (rc=$RC5, models: $(tr '\n' ' ' < "$T/models-called" 2>/dev/null))"
[ ! -f "$T/out.a5.cliffcap" ] \
  && ok || bad "A5: a cliff marker from the first attempt survived into the second: $(cat "$T/out.a5.cliffcap" 2>/dev/null)"

# --- A7: the ceiling knobs never leak into the session this call starts ------
: > "$T/logs/ALERTS.log"
RC7=$(run_call "$T/out.a7" testproj cliff-fixture-1 STUB_ENTRIES=40 \
        CONTEXT_KILL_TOKENS=150000 CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000)
[ "$(cat "$T/envsink" 2>/dev/null)" = "unset unset unset" ] \
  && ok || bad "A7: the child inherited the ceiling variables ('$(cat "$T/envsink" 2>/dev/null)') — every build it launches would be bounded by this lane's ceiling"
grep -q 'ceiling=150000' "$T/out.a7.ctxkill" 2>/dev/null \
  && ok || bad "A7: the operator override did not bind for THIS call: $(cat "$T/out.a7.ctxkill" 2>/dev/null)"
[ ! -f "$T/out.a7.cliffcap" ] \
  && ok || bad "A7: CONTEXT_KILL_TOKENS is the operator's own number — the cliff must not relabel it"

# --- A10: the adversarial negatives -------------------------------------------
# Each runs a 50,000-token session with a margin of 190,000. If the cliff were
# applied the ceiling would be 10,000 and the session would die; a survivor is
# the proof that the cliff was NOT applied. The positive control comes first,
# so a fixture that simply cannot kill anything cannot make the row pass.
neg() { # neg <name> <project> <model> [env...]
  local name="$1" proj="$2" mdl="$3"; shift 3
  local rc; rc=$(run_call "$T/out.n" "$proj" "$mdl" STUB_ENTRIES=10 \
    CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=190000 "$@")
  if [ "$rc" = 0 ] && [ ! -f "$T/out.n.ctxkill" ] && [ ! -f "$T/out.n.cliffcap" ]; then ok
  else bad "A10 $name: the ceiling was lowered by a cliff that must not apply (rc=$rc, ctxkill=$(cat "$T/out.n.ctxkill" 2>/dev/null), cliffcap=$(cat "$T/out.n.cliffcap" 2>/dev/null))"; fi
}
RCP=$(run_call "$T/out.n0" testproj cliff-fixture-1 STUB_ENTRIES=10 \
        CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=190000)
{ [ "$RCP" != 0 ] && [ -f "$T/out.n0.ctxkill" ]; } \
  && ok || bad "A10 control: a real cliff did NOT stop a 50K session at a 10,000 ceiling (rc=$RCP) — every negative below is vacuous"
neg "(c)1 no cliff_tokens key"   testproj nocliff-fixture
neg "(c)2 cliff_tokens null"     testproj nullcliff-fixture
neg "(c)3 cliff_tokens a string" testproj strcliff-fixture
neg "(c)4 model not in the table" testproj absent-fixture
neg "(c)5 MODEL_PRICES unreadable" testproj cliff-fixture-1 MODEL_PRICES="$T/no-such-table.json"
neg "(c)6a CONTEXT_KILL_CLIFF=0"  testproj cliff-fixture-1 CONTEXT_KILL_CLIFF=0
neg "(c)6b CONTEXT_KILL_CLIFF=yes" testproj cliff-fixture-1 CONTEXT_KILL_CLIFF=yes
neg "(c)9 lane with no ceiling"  freeproj cliff-fixture-1
# (c)6c — the variable unset entirely
RCU=$(run_call "$T/out.n6c" testproj cliff-fixture-1 STUB_ENTRIES=10 CONTEXT_KILL_CLIFF_MARGIN=190000)
{ [ "$RCU" = 0 ] && [ ! -f "$T/out.n6c.ctxkill" ] && [ ! -f "$T/out.n6c.cliffcap" ]; } \
  && ok || bad "A10 (c)6c: the cliff applied with CONTEXT_KILL_CLIFF unset (rc=$RCU)"
# (c)7 — the kill switches, with the cliff configured and a 200K session
touch "$T/flags/context-kill-off"
RCF=$(run_call "$T/out.n7" testproj cliff-fixture-1 STUB_ENTRIES=40 \
        CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000)
{ [ "$RCF" = 0 ] && [ ! -f "$T/out.n7.ctxkill" ] && [ ! -f "$T/out.n7.cliffcap" ]; } \
  && ok || bad "A10 (c)7a: flags/context-kill-off did not stop the cliff path (rc=$RCF)"
rm -f "$T/flags/context-kill-off"
RCO=$(run_call "$T/out.n7b" testproj cliff-fixture-1 STUB_ENTRIES=40 \
        CONTEXT_KILL=0 CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000)
{ [ "$RCO" = 0 ] && [ ! -f "$T/out.n7b.ctxkill" ] && [ ! -f "$T/out.n7b.cliffcap" ]; } \
  && ok || bad "A10 (c)7b: CONTEXT_KILL=0 did not stop the cliff path (rc=$RCO)"

# =============================================================================
# SECTION B/C — bin/watchdog-responder.sh
# =============================================================================
RH="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$RH" || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$RH/bin/lib" "$RH/logs" "$RH/locks" "$RH/env" "$RH/flags" \
         "$RH/state/responder" "$RH/state/build-queue/project-3" \
         "$T/rstub" "$T/calls" "$T/api" "$T/reg/catalog"

# Only the harness ROOT moves; every other byte is the production file.
sed "s|/root/harness|$RH|g" "$DIR/bin/watchdog-responder.sh" > "$RH/bin/watchdog-responder.sh"
chmod +x "$RH/bin/watchdog-responder.sh"
for s in fleet-conf.sh internal-token-for.sh board-fetch.sh box-for.sh; do
  ln -sf "$DIR/bin/$s" "$RH/bin/$s"
done
for l in gh-budget.sh lane-gate.sh lane-switch.sh env-path.sh; do
  ln -sf "$DIR/bin/lib/$l" "$RH/bin/lib/$l"
done
printf '#!/bin/sh\nexit 0\n' > "$RH/bin/stale-owed-tickets.sh"; chmod +x "$RH/bin/stale-owed-tickets.sh"
# BH-5942: a project run sources the per-project runner seam and its runner.
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$RH" ) >/dev/null || exit 1
printf 'PROJECT_1_INTERNAL_API_TOKEN=tok-m\n' > "$RH/env/project-1.env"
: > "$RH/env/global.env"
cat > "$RH/fleet.conf" <<'CONF'
project-1 example-org/project-1 https://project-1.invalid /api/board 2 local 127.0.0.1
CONF

# The registry the knobs are read out of is RENDERED from the real
# catalog/lanes.d/, so section B fails if the two knobs are not registered.
cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/lanes.d"
bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 \
  || bad "B: could not render a lane registry from catalog/lanes.d"

# The board API, the ticket and one open PR — trimmed from
# tests/responder-prefetch-test.sh's fixture to the one key this suite needs.
printf '[{"id":"b1","name":"Product"}]' > "$T/api/boards.json"
jq -nc '[{id:"t1",key:"TK-1"}]' > "$T/api/tickets.json"
jq -nc '{id:"t1",key:"TK-1",title:"Attachment upload dies on 12MB files",
         status:"review",waitingOn:"team",triageVerdict:"ready",
         turnChangedAt:"2026-09-16T00:00:00Z",updatedAt:"2026-09-16T12:00:00Z",
         comments:[{id:"c1",createdAt:"2026-09-01T00:00:00Z",author:{name:"Ana"},
                    isInternal:false,body:"the upload still dies"}]}' > "$T/api/t1.json"

cat > "$T/rstub/curl" <<STUBEOF
#!/bin/bash
OUTF=""; CODEW=0; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUTF="\${1:-}" ;;
    -w) shift; CODEW=1 ;;
    -H|-m|-A) shift ;;
    http*) URL="\$1" ;;
  esac
  shift
done
CODE=200; BODY=""
case "\$URL" in
  */boards)           BODY=\$(cat "$T/api/boards.json") ;;
  */boards/*/tickets) BODY=\$(cat "$T/api/tickets.json") ;;
  */tickets/t1)       BODY=\$(cat "$T/api/t1.json") ;;
  *) CODE=404; BODY="unknown url" ;;
esac
if [ -n "\$OUTF" ]; then printf '%s' "\$BODY" > "\$OUTF"; else printf '%s' "\$BODY"; fi
[ "\$CODEW" = 1 ] && printf '%s' "\$CODE"
exit 0
STUBEOF
chmod +x "$T/rstub/curl"
cat > "$T/rstub/gh" <<'STUBEOF'
#!/bin/bash
case "$1 ${2:-}" in
  "api rate_limit")
    printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":1},"graphql":{"remaining":5000,"limit":5000,"reset":1}}}'
    exit 0 ;;
  "auth token") echo "ghs_faketoken"; exit 0 ;;
esac
echo '[]'
STUBEOF
chmod +x "$T/rstub/gh"

# The recording agent-call stub. What it RECEIVES is the assertion.
cat > "$RH/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' ')
printf 'call=%s out=%s tokens=%s cliff=%s margin=%s\n' "$N" "$5" \
  "${CONTEXT_KILL_TOKENS:-unset}" "${CONTEXT_KILL_CLIFF:-unset}" \
  "${CONTEXT_KILL_CLIFF_MARGIN:-unset}" >> "$CALLDIR/calls.log"
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
printf '%b\n' "${STUB_DECISION:-}" > "$5"
case "$5" in
  */responder-run.project-1.txt)
    if [ "${STUB_ACT_KILL:-0}" = 1 ]; then
      printf 'ceiling=190000 total=260000 calls=9 session=s1\n' > "$5.ctxkill"
      [ "${STUB_ACT_CLIFF:-1}" = 1 ] \
        && printf 'cliff=200000 ceiling=190000 model=cliff-fixture-1 margin=10000\n' > "$5.cliffcap"
      exit 143
    fi ;;
esac
exit "${STUB_DECISION_RC:-0}"
STUB
chmod +x "$RH/bin/agent-call.sh"
cp "$RH/bin/agent-call.sh" "$T/agent-call.stub"

RNOW=$(date +%s)
seed_resp() { # seed_resp — one persisted stale-owed key, no cooldown, clean logs
  scratch_rm "$RH/state/responder"; scratch_rm "$RH/state/watchdog-responder"
  scratch_rm "$RH/state/gh-budget"; scratch_rm "$T/calls"
  mkdir -p "$RH/state/responder" "$RH/state/watchdog-responder/project-1" "$T/calls"
  : > "$RH/logs/responder.log"
  rm -f "$RH/logs/responder-run.project-1.txt.ctxkill" "$RH/logs/responder-run.project-1.txt.cliffcap"
  jq -nc '{"project-1":{count:1,tickets:[
      {key:"TK-1",title:"Attachment upload dies on 12MB files",status:"review",waitingOn:"team",hours:31}]}}' \
    > "$RH/state/stale-owed.json"
  jq -nc --argjson ts "$((RNOW-6000))" --slurpfile cur "$RH/state/stale-owed.json" \
    '{ts:$ts,snap:$cur[0]}' > "$RH/state/watchdog-responder/project-1/stale-history.json"
  echo '{}' > "$RH/state/responder/handled.json"
}
settings_rows() { # settings_rows [k=v ...] — the lane-gate settings cache
  local kv; local j='{}'
  for kv in "$@"; do
    j=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k]=$v' <<<"$j")
  done
  jq -nc --argjson fa "$(date +%s)" --argjson v "$j" '{fetched_at:$fa,values:$v}' \
    > "$RH/state/settings-cache.json"
}
run_resp_raw() { # run_resp_raw <env assignments...> — NO reseed, for B4
  ( export PATH="$T/rstub:$PATH" CALLDIR="$T/calls" GH_TOKEN=ghs_faketoken \
           FLEET_CONF="$RH/fleet.conf" LANE_REGISTRY="$T/reg/catalog/lanes.json" \
           TMPDIR="$T"
    env HARNESS="$RH" "$@" bash "$RH/bin/watchdog-responder.sh" project-1 >"$T/resp.out" 2>"$T/resp.err" )
  echo $?
}
run_resp() { # run_resp <env assignments...>
  seed_resp
  run_resp_raw "$@"
}
CALLS() { grep -c . "$T/calls/calls.log" 2>/dev/null || echo 0; }

# --- B1: a settings row is the ceiling, verbatim -----------------------------
settings_rows "lane.watchdog-responder.responder_context_cap_tokens=150000"
RB1=$(run_resp STUB_DECISION="DECISION: project-1:TK-1 :: buildable :: act :: nothing in flight")
CL1=$(sed -n 2p "$T/calls/calls.log" 2>/dev/null)
grep -q 'tokens=150000' <<<"$CL1" \
  && ok || bad "B1: the agent call did not receive CONTEXT_KILL_TOKENS=150000 (rc=$RB1): ${CL1:-<no call>} $(head -3 "$T/resp.err")"
grep -q 'cliff=unset' <<<"$CL1" \
  && ok || bad "B1: a lane with an explicit cap must not also arm the cliff path: $CL1"
CD1=$(head -1 "$T/calls/calls.log" 2>/dev/null)
{ grep -q 'tokens=unset' <<<"$CD1" && grep -q 'cliff=unset' <<<"$CD1"; } \
  && ok || bad "B1: the ceiling was exported, not passed per command — the decision call got it: $CD1"

# --- B2: no row means the cliff path, with the documented margin -------------
settings_rows
RB2=$(run_resp STUB_DECISION="DECISION: project-1:TK-1 :: buildable :: act :: nothing in flight")
CL2=$(sed -n 2p "$T/calls/calls.log" 2>/dev/null)
grep -q 'tokens=unset' <<<"$CL2" \
  && ok || bad "B2: with no cap row the lane still exported a verbatim ceiling (rc=$RB2): ${CL2:-<no call>}"
{ grep -q 'cliff=1' <<<"$CL2" && grep -q 'margin=10000' <<<"$CL2"; } \
  && ok || bad "B2: with no cap row the call did not arm the cliff at the default 10000 margin: $CL2"
CD2=$(head -1 "$T/calls/calls.log" 2>/dev/null)
grep -q 'cliff=unset' <<<"$CD2" \
  && ok || bad "B2: the cliff switch was exported, not passed per command — the decision call got it: $CD2"
settings_rows "lane.watchdog-responder.responder_cliff_margin_tokens=25000"
RB2B=$(run_resp STUB_DECISION="DECISION: project-1:TK-1 :: buildable :: act :: nothing in flight")
CL2B=$(sed -n 2p "$T/calls/calls.log" 2>/dev/null)
grep -q 'margin=25000' <<<"$CL2B" \
  && ok || bad "B2: the margin settings row was not read (rc=$RB2B): ${CL2B:-<no call>}"

# --- B3: one honest line when the act session is stopped ---------------------
settings_rows
RB3=$(run_resp STUB_DECISION="DECISION: project-1:TK-1 :: buildable :: act :: nothing in flight" \
        STUB_ACT_KILL=1)
NL3=$(grep -c 'act session CLIFF-AVOIDED:' "$RH/logs/responder.log" 2>/dev/null)
[ "$NL3" = 1 ] \
  && ok || bad "B3: expected exactly one 'act session CLIFF-AVOIDED:' line in responder.log, found $NL3 (rc=$RB3)"
L3=$(grep 'act session CLIFF-AVOIDED:' "$RH/logs/responder.log" 2>/dev/null | head -1)
grep -q 'stopped at 260000 against ceiling 190000' <<<"$L3" \
  && ok || bad "B3: the line does not carry the total and the ceiling: $L3"
grep -q 'cliff 200000 for cliff-fixture-1' <<<"$L3" \
  && ok || bad "B3: the line does not name the cliff and the model it came from: $L3"
grep -q 'no 2x bill' <<<"$L3" \
  && ok || bad "B3: the cliff stop does not say what the lowered ceiling bought: $L3"
# ...and the line agrees with the STATE. rc 143 is outside the 74..79 no-call
# family, so the keys ARE stamped: a line promising them back next tick would be
# false in the state that renders it.
grep -q 'cooldown' <<<"$L3" \
  && ok || bad "B3: the line does not say what happens to the keys this pass covered: $L3"
HS=$(jq -r '."project-1:TK-1" // empty' "$RH/state/responder/handled.json" 2>/dev/null)
[ -n "$HS" ] \
  && ok || bad "B3: the stopped pass did not stamp the key it was offered, so the log line and the state disagree"
# the same stop with no cliff marker reads as an ordinary context kill
settings_rows "lane.watchdog-responder.responder_context_cap_tokens=190000"
RB3B=$(run_resp STUB_DECISION="DECISION: project-1:TK-1 :: buildable :: act :: nothing in flight" \
        STUB_ACT_KILL=1 STUB_ACT_CLIFF=0)
L3B=$(grep 'act session' "$RH/logs/responder.log" 2>/dev/null | grep -E 'CONTEXT KILL|CLIFF-AVOIDED' | head -1)
grep -q 'act session CONTEXT KILL: stopped at 260000 against ceiling 190000' <<<"$L3B" \
  && ok || bad "B3: a stop with no cliff marker must not be labelled CLIFF-AVOIDED (rc=$RB3B): ${L3B:-<no line>}"
grep -q 'cliff' <<<"$L3B" \
  && bad "B3: a lane-cap stop names a cliff it never had: $L3B" || ok
# ...and it does not claim a billing event that was never in play. The 2x band
# is the cliff's, so a stop at the operator's own ceiling on a model with no
# cliff must not say a doubled bill was avoided.
grep -qE '2x bill' <<<"$L3B" \
  && bad "B3: a lane-cap stop claims it avoided a 2x bill: $L3B" || ok
# the cooldown wording is on BOTH lines — it is a fact of rc 143, not of the cliff
grep -q 'cooldown' <<<"$L3B" \
  && ok || bad "B3: the lane-cap stop does not say what happens to the keys this pass covered: $L3B"

# --- B4: a PREVIOUS tick's marker never becomes this tick's stop line --------
# $OUT is a fixed, reused path and agent-call only clears the markers inside its
# claude arm, so a tick whose ladder never reaches that arm would otherwise read
# yesterday's marker and log a stop that did not happen. The responder clears
# them itself before the call; the stub below writes none, so any 'act session
# CONTEXT KILL/CLIFF-AVOIDED' line here is a stale read.
settings_rows
seed_resp
printf 'ceiling=190000 total=260000 calls=9 session=s1\n' > "$RH/logs/responder-run.project-1.txt.ctxkill"
printf 'cliff=200000 ceiling=190000 model=cliff-fixture-1 margin=10000\n' > "$RH/logs/responder-run.project-1.txt.cliffcap"
RB4=$(run_resp_raw STUB_DECISION="DECISION: project-1:TK-1 :: buildable :: act :: nothing in flight")
[ "$(grep -c 'act session rc=' "$RH/logs/responder.log" 2>/dev/null)" -ge 1 ] \
  && ok || bad "B4: the act pass did not run, so the stale-marker check proves nothing (rc=$RB4): $(head -3 "$T/resp.err")"
[ "$(grep -cE 'act session (CONTEXT KILL|CLIFF-AVOIDED):' "$RH/logs/responder.log" 2>/dev/null)" = 0 ] \
  && ok || bad "B4: a previous tick's marker was logged as this tick's stop: $(grep -E 'act session (CONTEXT KILL|CLIFF-AVOIDED):' "$RH/logs/responder.log" | head -1)"
[ -f "$RH/logs/responder-run.project-1.txt.ctxkill" ] \
  && bad "B4: the stale ctxkill marker survived the pass that did not write it" || ok
[ -f "$RH/logs/responder-run.project-1.txt.cliffcap" ] \
  && bad "B4: the stale cliffcap marker survived the pass that did not write it" || ok

# --- C: the decision call, against the REAL bin/agent-call.sh ---------------
# The shim keeps $0 inside the repo so agent-call.sh finds its own libraries;
# HARNESS is still the scratch tree.
cat > "$RH/bin/agent-call.sh" <<SHIM
#!/bin/bash
echo "call \$1 \$2 \$3 notools=\${AGENT_CALL_NO_TOOLS:-unset} runners=\${AGENT_CALL_RUNNERS:-unset}" >> "$T/calls/calls.log"
exec bash "$DIR/bin/agent-call.sh" "\$@"
SHIM
chmod +x "$RH/bin/agent-call.sh"
cat > "$T/rstub/claude" <<'STUBEOF'
#!/bin/bash
mdl=""; prev=""
for a in "$@"; do case "$prev" in --model) mdl="$a" ;; esac; prev="$a"; done
echo "claude $mdl" >> "$CALLDIR/runners.log"
printf '{"result":"%b","usage":{"input_tokens":50,"output_tokens":10},"total_cost_usd":0.01}\n' \
  "${STUB_CLAUDE_OUT:-nothing to do}"
STUBEOF
chmod +x "$T/rstub/claude"
printf '#!/bin/bash\necho "grok" >> "$CALLDIR/runners.log"\necho GROK ANSWER\n' > "$T/rstub/grok"
chmod +x "$T/rstub/grok"
cp "$T/fakebin/timeout" "$T/rstub/timeout"
printf '#!/bin/bash\necho subscription\n' > "$RH/bin/billing-mode.sh"; chmod +x "$RH/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$RH/bin/beat.sh"; chmod +x "$RH/bin/beat.sh"

settings_rows
RC_C1=$(run_resp RUNNER_TRIAGE=grok COST_TRANSCRIPT_ROWS=0 HOME="$T" \
          STUB_CLAUDE_OUT="DECISION: project-1:TK-1 :: blocked :: none :: waiting on a merge")
grep -q 'decision call (no tools, claude) rc=0' "$RH/logs/responder.log" 2>/dev/null \
  && ok || bad "C1: no 'decision call (no tools, claude) rc=0' line — the pin did not hold with RUNNER_TRIAGE=grok (rc=$RC_C1): $(grep 'decision call' "$RH/logs/responder.log" 2>/dev/null | head -2)"
grep -q '^grok' "$T/calls/runners.log" 2>/dev/null \
  && bad "C1: the grok runner was executed for a no-tools call" || ok
grep -q 'runners=claude' "$T/calls/calls.log" 2>/dev/null \
  && ok || bad "C1: the decision call was not pinned with AGENT_CALL_RUNNERS=claude: $(cat "$T/calls/calls.log" 2>/dev/null)"
# C2 — one valid `none` decision buys no second call
NCC=$(grep -c '^call ' "$T/calls/calls.log" 2>/dev/null)
[ "$NCC" = 1 ] \
  && ok || bad "C2: a single 'none' decision still bought $NCC agent calls"
grep -q 'all 1 item(s) decided none' "$RH/logs/responder.log" 2>/dev/null \
  && ok || bad "C2: the 'all N item(s) decided none' line is missing: $(tail -3 "$RH/logs/responder.log" 2>/dev/null)"
# C3 — the fall-open path is untouched: nothing usable still runs the act pass
RC_C3=$(run_resp RUNNER_TRIAGE=grok COST_TRANSCRIPT_ROWS=0 HOME="$T" \
          STUB_CLAUDE_OUT="I could not decide anything")
grep -q 'decision call produced no decisions' "$RH/logs/responder.log" 2>/dev/null \
  && ok || bad "C3: an unusable decision answer did not log the fall-open (rc=$RC_C3)"
NCC3=$(grep -c '^call ' "$T/calls/calls.log" 2>/dev/null)
[ "$NCC3" = 2 ] \
  && ok || bad "C3: the fall-open tooled pass did not run ($NCC3 calls) — a broken decision step silenced the lane"

# --- T8: the lane's own header, and what it deliberately does NOT source -----
# The invariant is that the library is never SOURCED or RUN. The plan's own
# validate command is `grep -c conductor-mode.sh` = 0, which the header's
# sentence about the deliberate non-sourcing breaks by saying the name out
# loud; the assertion here is the one that is actually about behaviour —
# comments stripped, nothing left.
CMREF=$(sed -e 's/[[:space:]]#[[:space:]].*$//' -e '/^[[:space:]]*#/d' \
          "$DIR/bin/watchdog-responder.sh" | grep -c 'conductor-mode')
[ "$CMREF" = 0 ] \
  && ok || bad "T8: bin/watchdog-responder.sh sources or runs conductor-mode.sh ($CMREF references outside comments) — this lane consumes tickets and queue jobs, never alert lines"
grep -q 'conductor-mode.sh' "$DIR/bin/watchdog-responder.sh" \
  && ok || bad "T8: the header never says why conductor-mode.sh is not sourced here"

# =============================================================================
# A9 — the negative-scope case.
# =============================================================================
# SKIPS rather than fails when there is no branch diff to read (a merged main, a
# shallow CI clone): the assertion is about what THIS branch changed, and an
# empty diff is no evidence either way. It never passes by accident — every
# check below is only counted when the diff is genuinely there.
# The base is the MERGE BASE and the other side is the WORKING TREE, so the
# check reads the same before the commit and after it.
A9BASE=""
for b in main origin/main; do
  git -C "$DIR" rev-parse --verify -q "$b" >/dev/null 2>&1 \
    && { A9BASE=$(git -C "$DIR" merge-base "$b" HEAD 2>/dev/null) && [ -n "$A9BASE" ] && break; }
done
A9FILES=""
[ -n "$A9BASE" ] && A9FILES=$(git -C "$DIR" diff --name-only "$A9BASE" 2>/dev/null)
# THIS ARM JUDGES BH-1384's OWN SLICE ONLY (lead review, 2026-09-23). Same guard
# as tests/file-children.bh-981-test.sh: it bites only when the diff carries
# this ticket's own spec. On any other branch — a later PR that edits
# bin/agent-call.sh for its own ticket, or a Mergify merge-queue batch that
# carries this PR together with a sibling (draft #1691 went red on A9 because
# the batch diff held #1612's files) — "files outside BH-1384's paths" is not
# a finding, so the arm stays inert.
A9REF="${GITHUB_HEAD_REF:-$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
case "$A9REF" in mergify/merge-queue/*) A9FILES="" ;; esac
grep -q '^\.harness/specs/BH-1384/' <<<"$A9FILES" || A9FILES=""
if [ -z "$A9FILES" ]; then
  echo "A9: skipped — no BH-1384 branch diff against ${A9BASE:-<no base>} to scope-check (ref ${A9REF:-?})"
else
  STRAY=""
  while read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      bin/agent-call.sh|bin/watchdog-responder.sh|catalog/lanes.d/watchdog-responder.json) ;;
      tests/*|docs/*) ;;
      # The pipeline commits THIS ticket's plan as a spec artifact on top of the
      # build's own commit, so it is in the diff on every re-run and no human
      # wrote it. Scoped to this ticket's directory on purpose — a spec for some
      # OTHER ticket in this branch is still a stray. Same precedent as
      # tests/file-children.bh-981-test.sh.
      .harness/specs/BH-1384/*) ;;
      *) STRAY="$STRAY $f" ;;
    esac
  done <<<"$A9FILES"
  [ -z "$STRAY" ] \
    && ok || bad "A9: the branch changes files outside the three declared product paths (plus tests/docs):$STRAY"
  # No model literal enters the PRODUCT files. (The fixture tables above carry
  # model names on purpose — that is what a price fixture IS; the iron law is
  # about agent code resolving models through the DB-backed table.)
  PDIFF=$(git -C "$DIR" diff "$A9BASE" -- bin/agent-call.sh bin/watchdog-responder.sh \
            catalog/lanes.d/watchdog-responder.json 2>/dev/null)
  ADDED=$(printf '%s\n' "$PDIFF" | grep '^+' | grep -vE '^\+\+\+')
  MRE='(claude|grok|gpt|gemini)-[0-9a-z.-]+'
  # A literal that is on the REMOVED side too is a line this change reformatted,
  # not a model string it introduced.
  WAS=$(printf '%s\n' "$PDIFF" | grep '^-' | grep -vE '^---' | grep -oE "$MRE" | sort -u)
  NEWLIT=""
  for m in $(printf '%s\n' "$ADDED" | grep -oE "$MRE" | sort -u); do
    grep -qxF "$m" <<<"$WAS" || NEWLIT="$NEWLIT $m"
  done
  [ -z "$NEWLIT" ] \
    && ok || bad "A9: the product diff adds a hardcoded model literal:$NEWLIT"
  grep -q 'CAP_BYTES' <<<"$(printf '%s' "$ADDED")" \
    && bad "A9: the diff touches the evidence-bundle truncation, which is out of scope" || ok
  # ...and it touches no line of the GROK_MODEL cliff-ROUTE block, which is a
  # different mechanism on a different decision.
  OVERLAP=""
  while read -r hh; do
    case "$hh" in @@*) ;; *) continue ;; esac
    os=$(sed -n 's/^@@ -\([0-9]*\).*/\1/p' <<<"$hh"); ol=$(sed -n 's/^@@ -[0-9]*,\([0-9]*\).*/\1/p' <<<"$hh")
    [ -n "$os" ] || continue; [ -n "$ol" ] || ol=1
    [ "$os" -le 1860 ] && [ $(( os + ol - 1 )) -ge 1830 ] && OVERLAP="$OVERLAP $hh"
  done < <(git -C "$DIR" diff -U0 "$A9BASE" -- bin/agent-call.sh 2>/dev/null | grep '^@@')
  [ -z "$OVERLAP" ] \
    && ok || bad "A9: the diff touches bin/agent-call.sh 1830-1860, the GROK_MODEL cliff-route block:$OVERLAP"
fi

echo "responder-cliff.bh-1384-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

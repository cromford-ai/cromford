#!/bin/bash
# tests/context-kill-lanes.bh-2309-test.sh — the context kill ARMED on the
# build, preplan, lead-review, post-merge QA and product lanes, against the
# SHIPPED catalog/context-budgets.json, and the cost row a killed call leaves
# (BH-2309).
#
# WHY THE REAL MANIFEST. tests/context-kill.bh-653-test.sh proves the mechanism
# against a fixture lane. What this ticket ships is fifteen NUMBERS, so every
# section below reads catalog/context-budgets.json itself: a lane whose key is
# deleted, renamed or mistyped goes red here, not in production.
#
#   A      the resolver answers the shipped number for every armed stage, for a
#          wildcard project and a pinned one
#   A-neg  lanes outside the ticket stay unbounded; the three older ones are
#          unchanged
#   B      every number follows the sizing rule recorded next to it
#   C      bin/agent-call.sh on stage preplan-files (the smallest shipped
#          ceiling, 100,000) is really killed, and its logs/cost.csv row says
#          why in the note column: context-kill:ceiling=100000:total=<n>
#   C-neg  the same lane under its ceiling: rc 0, no marker, no note token
#   C-cliff a ceiling the price cliff lowered is labelled cliff-avoided:
#
# The fake `claude` is 653's: it grows a real session transcript that
# bin/transcript-cost.sh meters, 5,000 input tokens per entry.
# Run from anywhere: tests/context-kill-lanes.bh-2309-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-9536: the meter default is alert; this suite pins the kill mode
export CONTEXT_KILL_MODE=kill
DIR=$(cd "$(dirname "$0")/.." && pwd)
MAN="$DIR/catalog/context-budgets.json"
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/noenv" "$T/.claude/projects/-work"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The resolver, extracted the way docs/verification-map/context-kill.md tells an
# operator to call it.
ceiling() { # ceiling <stage> <project> [runner]
  ( unset CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_CLIFF
    export CONTEXT_BUDGETS="$MAN" HARNESS="$T"
    lane_switch() { [ -f "$HARNESS/flags/$1" ]; }   # agent-call.sh's no-lib shim (BH-2432)
    . <(sed -n '/^_ctx_kill_ceiling()/,/^}/p' "$DIR/bin/agent-call.sh")
    _ctx_kill_ceiling "$1" "$2" "${3:-claude}" )
}

# =============================================================================
# A. The resolver answers the shipped number, for any project.
# =============================================================================
while read -r stage want; do
  for proj in someproj project-5; do
    got=$(ceiling "$stage" "$proj")
    [ "$got" = "$want" ] \
      && ok || bad "A: stage $stage project $proj resolves to '${got:-<unbounded>}', want $want"
  done
done <<'EOF'
plan 7500000
execute 53600000
review 8000000
fix 59100000
preplan 11400000
preplan-files 100000
map 2700000
lead-review 8000000
prodqa 35000000
prd 3300000
mockup 4700000
revise 3300000
signals 5800000
synth 4700000
ideate 5200000
EOF

# =============================================================================
# A-neg. Out of scope stays unbounded; the three older lanes are unchanged.
#        BH-2538 armed qa, triage and decompose; eval, chat, repro and
#        orchestrator have too few or no measured rows and stay unbounded.
# =============================================================================
for stage in remediate probe takeover chat repro orchestrator eval; do
  got=$(ceiling "$stage" someproj)
  [ -z "$got" ] \
    && ok || bad "A-neg: stage $stage (project someproj) is now bounded at $got — this ticket arms only the named lanes"
done
[ "$(ceiling triage alert-triage)" = 400000 ] \
  && ok || bad "A-neg: alert-triage's ceiling moved: $(ceiling triage alert-triage)"
[ "$(ceiling triage responder)" = 6000000 ] \
  && ok || bad "A-neg: responder's ceiling moved: $(ceiling triage responder)"
ARMED=$(jq -r '[.lanes[]|select(.context_kill_tokens)|.lane]|sort|join(",")' "$MAN")
[ "$ARMED" = "alert-triage,build-execute,build-fix,build-plan,build-review,decompose,lead-review,postmerge-prodqa,preplan,preplan-files,preplan-map,product-ideation,product-mockup,product-prd,product-revise,product-signals,product-synth,project-triage,qa,responder,rule-miner" ] \
  && ok || bad "A-neg: the armed lane set is not the fifteen, the older three and BH-2538's measured three (six unmeasured lanes and the 10-row prompt-eval stay unarmed): $ARMED"

# =============================================================================
# B. Every number follows its recorded rule.
#    kill = max(ceil(1.25 * p99 / 100,000) * 100,000, 2 * ceiling_tokens)
#    (BH-2538 replaced BH-2309's 1.5 x p95 with a runaway backstop at 1.25 x
#    p99, and left lanes with no measured rows unarmed. Under 100 rows a lane
#    never goes below main's number (main-floor); under 30 rows it never arms a
#    lane main left unarmed (small-sample-unarmed).)
# =============================================================================
BERR=$(jq -r '
  (.lanes | map({key: .lane, value: .}) | from_entries) as $by
  | .lanes[] | select(.context_kill_basis) | . as $l | .context_kill_basis as $b
  | ( if $b.rule == "p99x1.25" then
        ([ (((1.25 * $b.p99 / 100000) | ceil) * 100000), (2 * $l.ceiling_tokens) ] | max) as $want
        | if $l.context_kill_tokens != $want then "\($l.lane): kill \($l.context_kill_tokens) != rule \($want)" else empty end
      elif $b.rule == "main-floor" then
        if $b.main_kill == null or $l.context_kill_tokens != $b.main_kill or $b.calls >= 100 then "\($l.lane): main-floor kill \($l.context_kill_tokens) vs main \($b.main_kill) on \($b.calls) rows" else empty end
      elif $b.rule == "small-sample-unarmed" then
        if $l.context_kill_tokens != null or $b.calls >= 30 or $b.main_kill != null then "\($l.lane): small-sample-unarmed is armed or not a small new lane" else empty end
      elif $b.rule == "unmeasured" then
        if $l.context_kill_tokens != null then "\($l.lane): unmeasured but armed at \($l.context_kill_tokens)"
        elif $b.calls != 0 or $b.p99 != null or $b.base != null then "\($l.lane): unmeasured basis carries rows"
        else empty end
      elif ($b.rule | startswith("analog:")) then
        ($b.rule | ltrimstr("analog:")) as $a
        | if $by[$a] == null then "\($l.lane): analog lane \($a) does not exist"
          elif $by[$a].context_kill_tokens != $l.context_kill_tokens then "\($l.lane): kill != analog \($a)"
          elif $b.calls != 0 or $b.p99 != null or $b.base != null then "\($l.lane): analog basis carries rows"
          else empty end
      else "\($l.lane): rule \($b.rule) is not p99x1.25 / main-floor / small-sample-unarmed / unmeasured / analog:<lane>" end ),
    ( if $b.rule == "p99x1.25" and ($b.calls < 1 or $b.base != $b.p99 or $b.p99 > $b.max) then "\($l.lane): p99 rule on \($b.calls) rows, base != p99 or p99 above max" else empty end ),
    ( if $b.rule == "p99x1.25" and $b.calls < 100 and $b.p99 != $b.max then "\($l.lane): \($b.calls) rows but p99 != max" else empty end ),
    ( if $l.context_kill_tokens == null then empty
      else [ $l.bounds[] | select(startswith("[lane:context_kill]")) ] as $kb
      | ($l.context_kill_tokens | tostring | explode | reverse
         | [recurse(if length > 3 then .[3:] else empty end) | .[:3] | reverse | implode] | reverse | join(",")) as $fmt
      | if ($kb | length) != 1 then "\($l.lane): \($kb | length) [lane:context_kill] bounds entries, want 1"
        elif ($kb[0] | contains($fmt) | not) then "\($l.lane): bounds entry does not name \($fmt)"
        else empty end end )
' "$MAN" 2>&1)
NB=$(jq '[.lanes[]|select(.context_kill_basis)]|length' "$MAN")
[ "$NB" = 25 ] \
  && ok || bad "B: $NB lanes carry a context_kill_basis, want 25"
[ -z "$BERR" ] \
  && ok || bad "B: numbers that do not follow their rule:
$BERR"

# =============================================================================
# C. The production entry point, on a shipped lane.
# =============================================================================
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
n=0
while [ "$n" -lt "${STUB_ENTRIES:-10}" ]; do
  n=$((n+1))
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-09-25T18:00:00Z","message":{"id":"msg_%s","model":"claude-fable-5-1","usage":{"input_tokens":5000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" >> "$PROJ/$sid.jsonl"
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
# A one-rung ladder, pinned the way tests/responder-cliff.bh-1384-test.sh pins
# it, so nothing here asks a live worker which models to walk.
mkdir -p "$T/state/model-routes"
for key in claude.ladder claude.ladder@testproj; do
  printf '0\tclaude-fable-5-1\tclaude\n' > "$T/state/model-routes/$key.tsv"
done

run_call() { # run_call <outfile> [env assignments...] ; echoes the rc
  local out="$1"; shift
  rm -f "$out" "$out.json" "$out.err" "$out.ctxkill" "$out.cliffcap" "$T/child.pid"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$MAN" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 HARNESS_ENV_DIR="$T/noenv"
    unset HARNESS_SECRET JOBS_URL CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_CLIFF
    env "$@" bash "$DIR/bin/agent-call.sh" preplan-files testproj claude-fable-5-1 60 "$out" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
cost_row() { grep ',preplan-files,claude,' "$T/logs/cost.csv" 2>/dev/null | tail -1; }
note_of()  { python3 -c 'import csv,sys; r=list(csv.reader([sys.argv[1]])); print(r[0][23] if r and len(r[0])>23 else "")' "$1"; }

# --- C: 40 x 5,000 = 200K against the shipped 100,000 -----------------------
: > "$T/logs/ALERTS.log"; : > "$T/logs/cost.csv"
RC=$(run_call "$T/out.kill" STUB_ENTRIES=40)
[ "$RC" != 0 ] \
  && ok || bad "C: an over-budget preplan-files call returned rc=0"
P=$(cat "$T/child.pid" 2>/dev/null)
{ [ -n "$P" ] && ! kill -0 "$P" 2>/dev/null; } \
  && ok || bad "C: the stub (pid ${P:-?}) is still alive after agent-call returned"
SID=$(sed -n 's/.*session=\([0-9a-f-]*\).*/\1/p' "$T/out.kill.ctxkill" 2>/dev/null)
N=$(grep -c '"usage"' "$T/.claude/projects/-work/$SID.jsonl" 2>/dev/null)
[ -n "$SID" ] && [ -n "$N" ] && [ "$N" -lt 40 ] \
  && ok || bad "C: the session was never cut short (session=${SID:-none}, entries=${N:-none}) — the shipped ceiling did not fire"
tail -1 "$T/out.kill" 2>/dev/null | grep -q '^CONTEXT KILL: preplan-files/testproj' \
  && ok || bad "C: \$OUT's last line is not the truncation marker: $(tail -1 "$T/out.kill" 2>/dev/null)"
[ "$(grep -c 'CONTEXT KILL' "$T/logs/ALERTS.log")" = 1 ] && grep -q 'ceiling 100000' "$T/logs/ALERTS.log" \
  && ok || bad "C: want exactly one CONTEXT KILL alert naming ceiling 100000: $(cat "$T/logs/ALERTS.log")"
ROW=$(cost_row)
RCF=$(cut -d, -f7 <<<"$ROW")
{ [ "$RCF" = 143 ] || [ "$RCF" = 137 ]; } \
  && ok || bad "C: the killed call's cost row rc is '${RCF:-<no row>}': $ROW"
NOTE=$(note_of "$ROW")
KT=$(sed -n 's/^.*context-kill:ceiling=100000:total=\([0-9][0-9]*\).*$/\1/p' <<<"$NOTE")
[ -n "$KT" ] && [ "$KT" -gt 100000 ] \
  && ok || bad "C: the killed call's cost row does not say why — note is '${NOTE}', want context-kill:ceiling=100000:total=<n above 100000>"
grep -q 'cliff-avoided' <<<"$NOTE" \
  && bad "C: a lane-cap kill was labelled cliff-avoided: $NOTE" || ok

# --- C-neg: 10 x 5,000 = 50K, under the ceiling ------------------------------
: > "$T/logs/ALERTS.log"; : > "$T/logs/cost.csv"
RC=$(run_call "$T/out.clean" STUB_ENTRIES=10)
[ "$RC" = 0 ] \
  && ok || bad "C-neg: an under-budget preplan-files call failed (rc=$RC)"
[ ! -f "$T/out.clean.ctxkill" ] \
  && ok || bad "C-neg: a .ctxkill marker was written for a session under its ceiling"
ROW=$(cost_row); NOTE=$(note_of "$ROW")
[ -n "$ROW" ] \
  && ok || bad "C-neg: no cost row for the clean call"
grep -qE 'context-kill|cliff-avoided' <<<"$NOTE" \
  && bad "C-neg: a clean call's cost row claims a kill: $NOTE" || ok

# --- C-cliff: the price cliff (60,000 - 10,000) is what lowered the ceiling --
# The shipped price table with one fact changed: the stub model gets a cliff.
jq '.per_token["claude-fable-5-1"].cliff_tokens = 60000' \
  "$DIR/catalog/model-prices.json" > "$T/prices.json"
: > "$T/logs/ALERTS.log"; : > "$T/logs/cost.csv"
RC=$(run_call "$T/out.cliff" STUB_ENTRIES=40 CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN=10000 MODEL_PRICES="$T/prices.json")
[ "$RC" != 0 ] \
  && ok || bad "C-cliff: a session past the cliff ceiling returned rc=0"
ROW=$(cost_row); NOTE=$(note_of "$ROW")
grep -qE '(^|;)cliff-avoided:ceiling=50000:total=[0-9]+' <<<"$NOTE" \
  && ok || bad "C-cliff: the cost row does not name the cliff as the bound that fired — note is '$NOTE'"
grep -q 'context-kill:' <<<"$NOTE" \
  && bad "C-cliff: a cliff-lowered kill was labelled a plain context-kill: $NOTE" || ok

echo "context-kill-lanes.bh-2309-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

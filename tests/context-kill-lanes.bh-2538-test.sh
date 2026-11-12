#!/bin/bash
# tests/context-kill-lanes.bh-2538-test.sh — the context kill on project-triage
# and the lanes that had none, every kill a RUNAWAY BACKSTOP sized at
# max(ceil(1.25 x p99 / 100K) x 100K, 2 x ceiling) from the 7-day measurement,
# lanes with no measured rows left UNARMED, a REAL triage shard stopped at the
# shipped number, and the same work killed twice escalated to a person instead
# of being bought again (BH-2538, lead fix round).
#
# Everything reads the SHIPPED catalog/context-budgets.json, the way
# tests/context-kill-lanes.bh-2309-test.sh does: what this ticket ships is
# numbers, so a key deleted, renamed or resized off its rule goes red here.
#
#   A1     triage for any unpinned project (and runner-bench's `bench`)
#          resolves to project-triage's number
#   A2     the measured named lanes resolve to their own number; the six with
#          no measured rows resolve UNBOUNDED and their record says UNARMED
#   A3     alert-triage / responder / rule-miner unchanged, pins still win, the
#          five lanes outside the ticket stay unbounded, the armed set is 21
#   B      every recorded basis: 7-day window, p95 <= p99 <= max, kill =
#          max(ceil(1.25 x p99 / 100K) x 100K, 2 x ceiling); analog lanes
#          carry their analog's number; a sample under 100 rows never cuts a
#          lane below main's number (main-floor), and a sample under 30 rows
#          never arms a lane main left unarmed (small-sample-unarmed)
#   F      the eight small-sample lanes the r2 review named, pinned
#   R      a real triage shard at project-triage's OLD p95-sized kill (the
#          number this PR first shipped, 1.3M) is NOT killed
#   E      bin/triage-shard.sh -> bin/agent-call.sh on a runaway session: the
#          child is killed, the cost row is refused with rc 143/137 and
#          context-kill:ceiling=<n>:total=<m>, the shard's rc is non-zero, the
#          ticket is re-armed, no codex failover
#   E-neg  the same shard under the number runs clean
#   E-off  CONTEXT_KILL=0 restores the unbounded path
#   K      the same ticket killed twice in 24h raises ONE critical alert; the
#          third call is refused rc 74 before the runner starts, with a refused
#          row and no second alert; the same ticket under a new fingerprint,
#          another ticket and a kill outside the window are not counted;
#          CONTEXT_KILL_REPEAT_MAX=0 turns it off
#   S      every lane's kill is a registered knob (lib.context-kill.*): a row
#          overrides the manifest (0 unarms, a row arms an unarmed lane), and a
#          settings outage serves the cached row or else the MANIFEST number,
#          never "no kill"; a real shard is killed at a row's number
#
# Run from anywhere: tests/context-kill-lanes.bh-2538-test.sh   (exit 0 = all pass)
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

ceiling() { # ceiling <stage> <project> [runner]
  ( unset CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_CLIFF
    export CONTEXT_BUDGETS="$MAN" HARNESS="$T"
    lane_switch() { [ -f "$HARNESS/flags/$1" ]; }   # agent-call.sh's no-lib shim (BH-2432)
    . <(sed -n '/^_ctx_kill_ceiling()/,/^}/p' "$DIR/bin/agent-call.sh")
    _ctx_kill_ceiling "$1" "$2" "${3:-claude}" )
}
lane_kill() { jq -r --arg l "$1" '.lanes[] | select(.lane == $l) | .context_kill_tokens // empty' "$MAN"; }

# =============================================================================
# A1. project-triage is armed, for any project that has no lane of its own.
# =============================================================================
PT=$(lane_kill project-triage)
[ -n "$PT" ] \
  && ok || bad "A1: project-triage carries no context_kill_tokens"
for proj in someproj project-5 cromford bench; do
  got=$(ceiling triage "$proj")
  { [ -n "$got" ] && [ "$got" = "$PT" ]; } \
    && ok || bad "A1: triage/$proj resolves to '${got:-<unbounded>}', want project-triage's ${PT:-<unset>}"
done

# =============================================================================
# A2. The named lanes WITH measured rows each at their own number; the six with
#     none are UNARMED (a kill sized off no data stops nearly every session:
#     every measured lane runs at 6.7-52x its declared ceiling), and their
#     record says so and says when they get armed.
# =============================================================================
while read -r lane stage proj; do
  want=$(lane_kill "$lane"); got=$(ceiling "$stage" "$proj")
  { [ -n "$want" ] && [ "$got" = "$want" ]; } \
    && ok || bad "A2: $lane ($stage/$proj) resolves to '${got:-<unbounded>}', lane carries '${want:-<no key>}'"
done <<'EOF'
decompose decompose someproj
qa qa someproj
EOF
while read -r lane stage proj; do
  got=$(ceiling "$stage" "$proj")
  [ -z "$got" ] \
    && ok || bad "A2: $lane ($stage/$proj) has no measured rows but is armed at $got"
  rec=$(jq -r --arg l "$lane" '.lanes[] | select(.lane == $l)
          | "\(.context_kill_basis.rule // "")|\(.context_kill_basis.calls // "")|\(.context_kill_note // "")"' "$MAN")
  case "$rec" in
    "unmeasured|0|"*UNARMED*"armed once"*) ok ;;
    *) bad "A2: $lane's record does not say it is unarmed until measured: $rec" ;;
  esac
done <<'EOF'
alerts-medic triage medic
orchestrator-turn orchestrator orchestrator
box-chat chat someproj
prebuild-repro repro someproj
trap-eval trapeval someproj
feature-map-draft feature-map-draft someproj
EOF
# prompt-eval: 10 rows, unarmed on main. Ten rows are no basis for a NEW kill.
got=$(ceiling eval someproj)
[ -z "$got" ] && ok || bad "A2: prompt-eval (10 rows, unarmed on main) is armed at $got"
[ "$(jq -r '.lanes[] | select(.lane == "prompt-eval") | .context_kill_basis.rule' "$MAN")" = small-sample-unarmed ] \
  && ok || bad "A2: prompt-eval's basis does not say small-sample-unarmed"

# =============================================================================
# A3. What this ticket does not move.
# =============================================================================
[ "$(ceiling triage alert-triage)" = 400000 ] \
  && ok || bad "A3: alert-triage's kill moved: $(ceiling triage alert-triage)"
[ "$(ceiling triage responder)" = 6000000 ] \
  && ok || bad "A3: responder's kill moved: $(ceiling triage responder)"
[ "$(ceiling mine rule-miner)" = 1500000 ] \
  && ok || bad "A3: rule-miner's kill moved: $(ceiling mine rule-miner)"
while read -r stage proj; do
  got=$(ceiling "$stage" "$proj")
  [ -z "$got" ] \
    && ok || bad "A3: $stage/$proj is now bounded at $got — the ticket does not name it"
done <<'EOF'
remediate someproj
probe someproj
takeover someproj
misc project-2-migration
cost_rows_db cromford
EOF
ARMED=$(jq -r '[.lanes[]|select(.context_kill_tokens)|.lane]|sort|join(",")' "$MAN")
[ "$ARMED" = "alert-triage,build-execute,build-fix,build-plan,build-review,decompose,lead-review,postmerge-prodqa,preplan,preplan-files,preplan-map,product-ideation,product-mockup,product-prd,product-revise,product-signals,product-synth,project-triage,qa,responder,rule-miner" ] \
  && ok || bad "A3: the armed lane set is not the 21 this ticket ships: $ARMED"

# =============================================================================
# B. Every armed number is the backstop rule over its recorded 7-day basis.
#    kill = max(ceil(1.25 * p99 / 100,000) * 100,000, 2 * ceiling_tokens)
#    p99 is sorted[min(n-1, int(n * 0.99))], so under 100 rows it IS the max.
# =============================================================================
NB=$(jq '[.lanes[]|select(.context_kill_basis)]|length' "$MAN")
[ "$NB" = 25 ] \
  && ok || bad "B: $NB lanes carry a context_kill_basis, want 25 (18 armed by it, 7 recorded unarmed)"
BERR=$(jq -r '
  def win: (.window // "" | split("..")) as $w
    | if ($w | length) != 2 then null
      else (($w[1] | fromdateiso8601) - ($w[0] | fromdateiso8601)) end;
  def rule($p99; $l): ([ (((1.25 * $p99) / 100000) | ceil) * 100000, 2 * $l.ceiling_tokens ] | max);
  (.lanes | map({key: .lane, value: .}) | from_entries) as $by
  | .lanes[] | select(.context_kill_basis) | . as $l | .context_kill_basis as $b
  | ( if $b.rule == "p99x1.25" then
        if ($b.p99 | type) != "number" then "\($l.lane): p99x1.25 with no p99"
        elif $l.context_kill_tokens != rule($b.p99; $l) then "\($l.lane): kill \($l.context_kill_tokens) != rule \(rule($b.p99; $l))"
        elif $b.calls < 1 then "\($l.lane): p99 over \($b.calls) rows"
        elif $b.p99 > $b.max then "\($l.lane): p99 \($b.p99) above max \($b.max)"
        elif ($b.p95 != null) and ($b.p99 < $b.p95) then "\($l.lane): p99 \($b.p99) below p95 \($b.p95)"
        elif $b.calls < 100 and $b.p99 != $b.max then "\($l.lane): \($b.calls) rows but p99 != max"
        elif $b.base != $b.p99 then "\($l.lane): base != p99"
        elif $b.calls < 100 and $b.main_kill != null and $l.context_kill_tokens < $b.main_kill then "\($l.lane): \($b.calls) rows cut the kill below the main kill \($b.main_kill)"
        elif $b.calls < 30 and $b.main_kill == null then "\($l.lane): \($b.calls) rows armed a lane main left unarmed"
        else empty end
      elif $b.rule == "main-floor" then
        if $b.main_kill == null or $l.context_kill_tokens != $b.main_kill then "\($l.lane): main-floor kill \($l.context_kill_tokens) != main \($b.main_kill)"
        elif $b.calls >= 100 then "\($l.lane): main-floor on \($b.calls) rows — 100+ rows size the lane"
        elif ($b.p99 | type) != "number" or $b.p99 != $b.max then "\($l.lane): main-floor p99 != max"
        elif rule($b.p99; $l) > $b.main_kill then "\($l.lane): main-floor although the rule \(rule($b.p99; $l)) is higher"
        else empty end
      elif $b.rule == "small-sample-unarmed" then
        if $l.context_kill_tokens != null then "\($l.lane): small-sample-unarmed but armed at \($l.context_kill_tokens)"
        elif $b.calls >= 30 or $b.main_kill != null then "\($l.lane): small-sample-unarmed on \($b.calls) rows, main \($b.main_kill)"
        else empty end
      elif $b.rule == "unmeasured" then
        if $l.context_kill_tokens != null then "\($l.lane): unmeasured but armed at \($l.context_kill_tokens)"
        elif $b.calls != 0 or $b.p99 != null or $b.base != null then "\($l.lane): unmeasured basis carries rows"
        else empty end
      elif ($b.rule | startswith("analog:")) then
        ($b.rule | ltrimstr("analog:")) as $a
        | if $by[$a] == null then "\($l.lane): analog lane \($a) does not exist"
          elif $by[$a].context_kill_tokens != $l.context_kill_tokens then "\($l.lane): kill != analog \($a)"
          elif $b.main_kill != null and $l.context_kill_tokens < $b.main_kill then "\($l.lane): analog kill below the main kill \($b.main_kill)"
          elif $b.calls != 0 or $b.p99 != null or $b.base != null then "\($l.lane): analog basis carries rows"
          else empty end
      else "\($l.lane): rule \($b.rule) is not p99x1.25 / main-floor / small-sample-unarmed / unmeasured / analog:<lane>" end ),
    ( if ($b | has("main_kill")) then empty else "\($l.lane): basis does not record main_kill" end ),
    ( if $b.rule == "p99x1.25" or $b.rule == "main-floor" then ($b | win) as $s
        | if $s == null then "\($l.lane): window \($b.window) is not <iso>..<iso>"
          elif $s < 561600 or $s > 648000 then "\($l.lane): window spans \($s)s, not 7 days"
          else empty end
      else empty end ),
    ( if ($b.unit | tostring | startswith("input_toks + cache_read")) then empty else "\($l.lane): unit is \($b.unit)" end ),
    ( if ($l.context_kill_note | tostring | contains("BH-2538")) then empty else "\($l.lane): context_kill_note does not name BH-2538" end ),
    ( [ ($l.bounds // [])[] | select(startswith("[lane:context_kill]")) ] as $kb
      | if $l.context_kill_tokens == null then
          (if ($kb | length) != 0 then "\($l.lane): unarmed but carries a [lane:context_kill] bounds entry" else empty end)
        else
          ($l.context_kill_tokens | tostring | explode | reverse
           | [recurse(if length > 3 then .[3:] else empty end) | .[:3] | reverse | implode] | reverse | join(",")) as $fmt
          | if ($kb | length) != 1 then "\($l.lane): \($kb | length) [lane:context_kill] bounds entries, want 1"
            elif ($kb[0] | contains($fmt) | not) then "\($l.lane): bounds entry does not name \($fmt)"
            else empty end
        end )
' "$MAN" 2>&1)
[ -z "$BERR" ] \
  && ok || bad "B: numbers that do not follow their rule:
$BERR"
# No armed lane is a budget: every measured number sits at least 1.25 x p99.
LOW=$(jq -r '.lanes[] | select(.context_kill_basis.rule == "p99x1.25")
         | select(.context_kill_tokens < 1.25 * .context_kill_basis.p99) | .lane' "$MAN")
[ -z "$LOW" ] \
  && ok || bad "B: kills below 1.25 x p99 (a budget, not a backstop): $LOW"

# =============================================================================
# F. The small samples the r2 review named: a handful of rows never tightens a
#    lane below main, and never arms one main left unarmed.
# =============================================================================
while read -r lane want; do
  got=$(lane_kill "$lane")
  [ "${got:-unarmed}" = "$want" ] \
    && ok || bad "F: $lane kills at '${got:-unarmed}', want $want (main's number is the floor for a small sample)"
done <<'EOF'
product-mockup 4700000
product-prd 3300000
product-revise 3300000
product-signals 5800000
product-synth 4700000
preplan-map 2700000
product-ideation 5200000
prompt-eval unarmed
EOF

# =============================================================================
# E. The production entry point: a real triage shard over the shipped kill.
# =============================================================================
# agent-call.sh resolves bin/transcript-cost.sh from dirname "$0", so the
# harness copy is a wrapper that execs the checkout's file, never a symlink.
printf '#!/bin/bash\nexec bash "%s/bin/agent-call.sh" "$@"\n' "$DIR" > "$T/bin/agent-call.sh"
chmod +x "$T/bin/agent-call.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$T/bin/triage-contract.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/decision-log.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
chmod +x "$T/bin/triage-contract.sh" "$T/bin/decision-log.sh" "$T/bin/beat.sh" "$T/bin/billing-mode.sh"

# 653's fake claude, with the tokens per entry a parameter: it grows the real
# session transcript bin/transcript-cost.sh meters.
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
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"2026-09-25T18:00:00Z","message":{"id":"msg_%s","model":"claude-fable-5-1","usage":{"input_tokens":%s,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$n" "$n" "$STUB_TOKENS" >> "$PROJ/$sid.jsonl"
  sleep 0.2
done
# STUB_HOLD: stay alive at the final total, so the meter reads it at least once.
sleep "${STUB_HOLD:-0}"
printf '{"result":"tickets=1 CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
printf '#!/bin/bash\ntouch "$T_DIR/codex.called"\necho codex\n' > "$T/fakebin/codex"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/claude" "$T/fakebin/codex" "$T/fakebin/timeout"
mkdir -p "$T/state/model-routes"
for key in claude.ladder claude.ladder@shardproj; do
  printf '0\tclaude-fable-5-1\tclaude\n' > "$T/state/model-routes/$key.tsv"
done
printf 'Triage ticket BH-1 on shardproj.\n' > "$T/prompt.txt"

run_shard() { # run_shard [env assignments...] ; echoes the shard's own rc
  rm -f "$T/logs/shardproj.triage-BH-1.out"* "$T/child.pid" "$T/codex.called"
  : > "$T/logs/ALERTS.log"; : > "$T/logs/cost.csv"; : > "$T/logs/shardproj.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$MAN" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 HARNESS_ENV_DIR="$T/noenv" \
           TSH_RUNNER=claude TSH_MODEL=claude-fable-5-1 RUNNER_TRIAGE_FALLBACK=codex
    unset HARNESS_SECRET JOBS_URL CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_CLIFF
    env "$@" bash "$DIR/bin/triage-shard.sh" shardproj BH-1 "$T/prompt.txt" >/dev/null 2>&1 )
  echo $?
}
cost_row() { grep ',shardproj,triage,claude,' "$T/logs/cost.csv" 2>/dev/null | tail -1; }
note_of()  { python3 -c 'import csv,sys; r=list(csv.reader([sys.argv[1]])); print(r[0][23] if r and len(r[0])>23 else "")' "$1"; }
entries()  { local sid; sid=$(ls -t "$T/.claude/projects/-work/" 2>/dev/null | head -1); grep -c '"usage"' "$T/.claude/projects/-work/$sid" 2>/dev/null; }

PTN=${PT:-1000000}
# Nine entries cross the number; forty would be 4.4 x it.
OVER=$(( PTN / 8 + 1 ))

# --- E: over the shipped project-triage kill ---------------------------------
scratch_rm "$T/.claude/projects/-work"; mkdir -p "$T/.claude/projects/-work"
RC=$(run_shard STUB_ENTRIES=40 STUB_TOKENS=$OVER)
OUT="$T/logs/shardproj.triage-BH-1.out"
[ "$RC" = 0 ] \
  && ok || bad "E: triage-shard.sh itself exited rc=$RC (it always ends 0 and reports the call's rc)"
P=$(cat "$T/child.pid" 2>/dev/null)
{ [ -n "$P" ] && ! kill -0 "$P" 2>/dev/null; } \
  && ok || bad "E: the stub (pid ${P:-?}) is still alive after the shard returned"
N=$(entries)
{ [ -n "$N" ] && [ "$N" -lt 40 ]; } \
  && ok || bad "E: the session was never cut short (entries=${N:-none}) — project-triage's kill did not fire"
tail -1 "$OUT" 2>/dev/null | grep -q '^CONTEXT KILL: triage/shardproj' \
  && ok || bad "E: \$OUT's last line is not the truncation marker: $(tail -1 "$OUT" 2>/dev/null)"
{ [ "$(grep -c 'CONTEXT KILL' "$T/logs/ALERTS.log")" = 1 ] && grep -q "ceiling $PTN" "$T/logs/ALERTS.log"; } \
  && ok || bad "E: want exactly one CONTEXT KILL alert naming ceiling $PTN: $(grep 'CONTEXT KILL' "$T/logs/ALERTS.log")"
ROW=$(cost_row)
RCF=$(cut -d, -f7 <<<"$ROW")
{ [ "$RCF" = 143 ] || [ "$RCF" = 137 ]; } \
  && ok || bad "E: the refused row's rc is '${RCF:-<no row>}': $ROW"
NOTE=$(note_of "$ROW")
KT=$(sed -n "s/^.*context-kill:ceiling=$PTN:total=\([0-9][0-9]*\).*\$/\1/p" <<<"$NOTE")
{ [ -n "$KT" ] && [ "$KT" -gt "$PTN" ]; } \
  && ok || bad "E: the refused row does not say why — note '$NOTE', want context-kill:ceiling=$PTN:total=<n above it>"
grep -qE "\] shard BH-1 rc=[1-9][0-9]* ::" "$T/logs/shardproj.log" \
  && ok || bad "E: the shard's log line does not carry a non-zero rc: $(grep 'shard BH-1' "$T/logs/shardproj.log")"
grep -q 'triage shard exited rc=' "$T/logs/ALERTS.log" \
  && ok || bad "E: the killed shard did not say it put its ticket back: $(cat "$T/logs/ALERTS.log")"
[ ! -e "$T/codex.called" ] \
  && ok || bad "E: a context kill failed over to codex — it is a policy stop"

# --- E-neg: half the number ---------------------------------------------------
scratch_rm "$T/.claude/projects/-work"; mkdir -p "$T/.claude/projects/-work"
RC=$(run_shard STUB_ENTRIES=10 STUB_TOKENS=$(( PTN / 20 )))
[ ! -f "$OUT.ctxkill" ] \
  && ok || bad "E-neg: a .ctxkill marker was written for a shard under the kill"
grep -q 'CONTEXT KILL' "$T/logs/ALERTS.log" \
  && bad "E-neg: an under-budget shard raised a CONTEXT KILL alert" || ok
grep -qE "\] shard BH-1 rc=0 ::" "$T/logs/shardproj.log" \
  && ok || bad "E-neg: the under-budget shard did not finish rc=0: $(grep 'shard BH-1' "$T/logs/shardproj.log")"
ROW=$(cost_row); NOTE=$(note_of "$ROW")
{ [ -n "$ROW" ] && ! grep -q 'context-kill' <<<"$NOTE"; } \
  && ok || bad "E-neg: cost row missing or claims a kill: '$ROW' note '$NOTE'"

# --- E-off: the switch restores the unbounded path ----------------------------
scratch_rm "$T/.claude/projects/-work"; mkdir -p "$T/.claude/projects/-work"
RC=$(run_shard STUB_ENTRIES=40 STUB_TOKENS=$OVER CONTEXT_KILL=0)
N=$(entries)
{ [ "$N" = 40 ] && [ ! -f "$OUT.ctxkill" ]; } \
  && ok || bad "E-off: CONTEXT_KILL=0 still cut the session (entries=${N:-none})"
grep -qE "\] shard BH-1 rc=0 ::" "$T/logs/shardproj.log" \
  && ok || bad "E-off: the unkilled shard did not finish rc=0: $(grep 'shard BH-1' "$T/logs/shardproj.log")"

# --- R: the number this PR first shipped (1.3M = project-triage's p95) is no
#     longer a kill. A session just over it is a normal busy shard. -----------
scratch_rm "$T/.claude/projects/-work"
mkdir -p "$T/.claude/projects/-work"
RC=$(run_shard STUB_ENTRIES=10 STUB_TOKENS=135000 STUB_HOLD=4)
N=$(entries)
{ [ "$N" = 10 ] && [ ! -f "$OUT.ctxkill" ]; } \
  && ok || bad "R: a 1,350,000-token triage shard (over the old 1,300,000 p95 kill) was cut (entries=${N:-none}); project-triage kill is ${PT:-<unset>}"
grep -q 'CONTEXT KILL' "$T/logs/ALERTS.log" \
  && bad "R: a shard at the old p95 raised a CONTEXT KILL alert" || ok
grep -qE "\] shard BH-1 rc=0 ::" "$T/logs/shardproj.log" \
  && ok || bad "R: the shard at the old p95 did not finish rc=0: $(grep 'shard BH-1' "$T/logs/shardproj.log")"

# =============================================================================
# K. The same work killed twice in the window goes to a person, and is not
#    bought a third time. The count is the cost.csv ledger's killed rows.
# =============================================================================
shard() { # shard <key> [env assignments...] — run_shard, but the ledger is KEPT
  local key="$1"; shift
  rm -f "$T/logs/shardproj.triage-$key.out"* "$T/child.pid" "$T/codex.called"
  # The dispatcher's board-state stamp (BH-1015): the ticket's K3 fingerprint.
  mkdir -p "$T/state/triage-shards/shardproj"
  printf '%s\n' "$(printf '%s' "$key${FP_SALT:-}" | sha256sum | cut -c1-40)" > "$T/state/triage-shards/shardproj/$key.fp"
  scratch_rm "$T/.claude/projects/-work"
  mkdir -p "$T/.claude/projects/-work"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$MAN" CONTEXT_KILL_POLL_S=1 \
           COST_TRANSCRIPT_ROWS=1 HARNESS_ENV_DIR="$T/noenv" \
           TSH_RUNNER=claude TSH_MODEL=claude-fable-5-1 RUNNER_TRIAGE_FALLBACK=codex
    unset HARNESS_SECRET JOBS_URL CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_CLIFF \
          CONTEXT_KILL_REPEAT_MAX CONTEXT_KILL_REPEAT_WINDOW_S
    env "$@" bash "$DIR/bin/triage-shard.sh" shardproj "$key" "$T/prompt.txt" >/dev/null 2>&1 )
}
repeated() { grep -c 'CONTEXT KILL REPEATED' "$T/logs/ALERTS.log"; }
kill_rows() { grep ',shardproj,triage,claude,' "$T/logs/cost.csv" | grep -c "context-kill:ceiling=.*:tk=$1:fp="; }
RUNAWAY="STUB_ENTRIES=40 STUB_TOKENS=$OVER"
# bin/triage-shard.sh reads the stamp through $HARNESS/bin/lib/triage-shards-lib.sh.
# The scratch harness gets exactly the real lib's path function, extracted, so
# the shard hands agent-call.sh its K3 fingerprint as the dispatcher's would.
mkdir -p "$T/bin/lib"
sed -n '/^triage_shard_fp_file()/p' "$DIR/bin/lib/triage-shards-lib.sh" > "$T/bin/lib/triage-shards-lib.sh"
grep -q '^triage_shard_fp_file()' "$T/bin/lib/triage-shards-lib.sh" \
  && ok || bad "K: could not extract triage_shard_fp_file from bin/lib/triage-shards-lib.sh"

: > "$T/logs/cost.csv"; : > "$T/logs/ALERTS.log"; : > "$T/logs/shardproj.log"
scratch_rm "$T/state/alerts"
# A kill of the same ticket from 2020 is outside any 24h window.
printf '%s\n' "2020-01-01T00:00:00Z,box,shardproj,triage,claude,claude-fable-5-1,143,60,9000000,10,0,0,1.00,subscription,none,unknown,s-old,transcript,,,,,,context-kill:ceiling=1:total=2:tk=BH-1:fp=0000000000000000," >> "$T/logs/cost.csv"

# shellcheck disable=SC2086 # RUNAWAY is two env assignments on purpose
shard BH-1 $RUNAWAY
[ "$(kill_rows BH-1)" = 2 ] \
  && ok || bad "K: the first BH-1 kill's row does not name its work (tk=BH-1:fp=...): $(grep context-kill "$T/logs/cost.csv" | tail -1)"
grep -v '^2020-' "$T/logs/cost.csv" | grep -c 'context-kill:ceiling=[0-9]*:total=[0-9]*:tk=BH-1:fp=[0-9a-f]\{16\}' | grep -qx 1 \
  && ok || bad "K: the kill row's fp is not 16 hex: $(grep context-kill "$T/logs/cost.csv" | tail -1)"
[ "$(repeated)" = 0 ] \
  && ok || bad "K: one kill in the window (plus one from 2020) already escalated: $(grep 'REPEATED' "$T/logs/ALERTS.log")"

# shellcheck disable=SC2086
shard BH-2 $RUNAWAY
[ "$(repeated)" = 0 ] \
  && ok || bad "K: a kill of ANOTHER ticket was counted against BH-1: $(grep 'REPEATED' "$T/logs/ALERTS.log")"

# shellcheck disable=SC2086
shard BH-1 $RUNAWAY
[ -s "$T/child.pid" ] \
  && ok || bad "K: the second BH-1 call never reached the runner — only the third may be refused"
[ "$(repeated)" = 1 ] \
  && ok || bad "K: the second BH-1 kill in the window raised $(repeated) CONTEXT KILL REPEATED alerts, want exactly 1"
grep 'CONTEXT KILL REPEATED' "$T/logs/ALERTS.log" | grep -q 'triage/shardproj work tk=BH-1 ' \
  && ok || bad "K: the escalation does not name the lane and the ticket: $(grep 'REPEATED' "$T/logs/ALERTS.log")"

# The third call for BH-1: refused before the runner, nothing bought.
KILLS_BEFORE=$(kill_rows BH-1)
# shellcheck disable=SC2086
shard BH-1 $RUNAWAY
KOUT="$T/logs/shardproj.triage-BH-1.out"
[ ! -e "$T/child.pid" ] \
  && ok || bad "K: the third BH-1 call started the runner — auto-retry was not stopped"
head -1 "$KOUT" 2>/dev/null | grep -q '^AGENT_CALL_REFUSED context-kill repeat triage kills=2 tk=BH-1 ' \
  && ok || bad "K: the refused call's \$OUT does not say why: $(head -1 "$KOUT" 2>/dev/null)"
LAST=$(grep ',shardproj,triage,' "$T/logs/cost.csv" | tail -1)
{ [ "$(cut -d, -f7 <<<"$LAST")" = 74 ] && grep -q 'refused:context-kill-repeat' <<<"$LAST"; } \
  && ok || bad "K: the refused call left no rc 74 refused:context-kill-repeat row: $LAST"
[ "$(kill_rows BH-1)" = "$KILLS_BEFORE" ] \
  && ok || bad "K: the refused call wrote another kill row"
[ "$(repeated)" = 1 ] \
  && ok || bad "K: the refusal raised a second escalation ($(repeated) REPEATED lines) — one alert per piece of work"
grep -q 'context-kill repeat refused before the call' "$T/logs/shardproj.log" \
  && ok || bad "K: the shard did not log the refusal: $(tail -2 "$T/logs/shardproj.log")"
grep -q 'triage shard exited rc=74' "$T/logs/ALERTS.log" \
  && bad "K: a refused repeat wrote a per-tick 'triage shard exited' ALERTS line" || ok

# The ticket's world moved (a client answered): a NEW fingerprint is new work,
# so the match is ticket AND fingerprint when a call declares both.
FP_SALT=answered shard BH-1 STUB_ENTRIES=3 STUB_TOKENS=1000
[ -s "$T/child.pid" ] \
  && ok || bad "K: BH-1 under a NEW fingerprint (its thread changed) was still refused"

# Another ticket is still served, and the knob turns the stop off.
shard BH-3 STUB_ENTRIES=3 STUB_TOKENS=1000
[ -s "$T/child.pid" ] \
  && ok || bad "K: BH-3 (never killed) was refused"
shard BH-1 STUB_ENTRIES=3 STUB_TOKENS=1000 CONTEXT_KILL_REPEAT_MAX=0
[ -s "$T/child.pid" ] \
  && ok || bad "K: CONTEXT_KILL_REPEAT_MAX=0 still refused BH-1"

# =============================================================================
# S. Every lane's kill is a registered settings knob (lib.context-kill.*): a row
#    overrides the manifest, and a settings outage falls back to the MANIFEST
#    number, never to "no kill". LANE_GATE_NOW pins the cache clock.
# =============================================================================
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 \
  && ok || bad "S: lanes-build.sh could not compose the registry"
# S1. One knob per manifest lane that carries a kill or a basis, named after it,
#     its default the manifest's number (0 = unarmed), and agent-call reads it.
SERR=$(jq -r --slurpfile m "$MAN" '
  ([.libs[]? | select(.id == "context-kill") | .knobs[]] | map({key: .env, value: .}) | from_entries) as $k
  | $m[0].lanes[] | select(.context_kill_tokens or .context_kill_basis)
  | ("CONTEXT_KILL_TOKENS_" + (.lane | ascii_upcase | gsub("-"; "_"))) as $e
  | if $k[$e] == null then "\(.lane): no registered knob \($e)"
    elif $k[$e].default != (.context_kill_tokens // 0) then "\(.lane): knob default \($k[$e].default) != manifest \(.context_kill_tokens // 0)"
    elif $k[$e].zero_means != "unarmed" then "\(.lane): 0 does not mean unarmed"
    else empty end' "$REG" 2>&1)
NK=$(jq '[.libs[]? | select(.id == "context-kill") | .knobs[]] | length' "$REG")
{ [ -z "$SERR" ] && [ "$NK" = 28 ]; } \
  && ok || bad "S1: the kill knobs do not mirror the manifest ($NK knobs): $SERR"
for e in $(jq -r '.libs[]? | select(.id == "context-kill") | .knobs[].env' "$REG"); do
  # grep -c, not -q: under pipefail an early -q exit SIGPIPEs the first grep.
  [ "$(grep -v '^[[:space:]]*#' "$DIR/bin/agent-call.sh" | grep -cw -- "$e")" -gt 0 ] \
    || { bad "S1: bin/agent-call.sh never reads $e"; continue; }
  ok
done

# kill_with <cache-json|none> — the resolver as agent-call.sh runs it: lane-gate
# applies the context-kill rows, then _ctx_kill_ceiling answers for triage.
kill_with() {
  scratch_rm "$T/state/lane-gate"; rm -f "$T/state/settings-cache.json"
  [ "$1" = none ] || printf '%s\n' "$1" > "$T/state/settings-cache.json"
  ( unset CONTEXT_KILL CONTEXT_KILL_TOKENS CONTEXT_KILL_CLIFF JOBS_URL HARNESS_SECRET LANE_GATE_DISABLE
    for v in ${!CONTEXT_KILL_TOKENS_@}; do unset "$v"; done
    export CONTEXT_BUDGETS="$MAN" HARNESS="$T" LANE_REGISTRY="$REG" LANE_GATE_NOW=1000000 HARNESS_ENV_DIR="$T/noenv"
    . "$DIR/bin/lib/lane-gate.sh" 2>/dev/null
    lib_env_apply context-kill
    lane_switch() { [ -f "$HARNESS/flags/$1" ]; }   # agent-call.sh's no-lib shim (BH-2432)
    . <(sed -n '/^_ctx_kill_row()/,/^}/p; /^_ctx_kill_ceiling()/,/^}/p' "$DIR/bin/agent-call.sh")
    _ctx_kill_ceiling "${2:-triage}" "${3:-someproj}" claude )
}
row() { printf '{"fetched_at":%s,"values":{"%s":"%s"},"seeded":{}}' "$1" "$2" "$3"; }
KEY=lib.context-kill.context_kill_tokens_project_triage

# S2. a fresh row overrides the manifest, both directions
got=$(kill_with "$(row 1000000 $KEY 9000000)")
[ "$got" = 9000000 ] && ok || bad "S2: a fresh row of 9,000,000 resolved to '${got:-<unbounded>}', manifest $PT"
got=$(kill_with "$(row 1000000 $KEY 1000000)")
[ "$got" = 1000000 ] && ok || bad "S2: a fresh row of 1,000,000 resolved to '${got:-<unbounded>}'"
# S3. a row of 0 unarms the lane; a row arms an UNARMED lane
got=$(kill_with "$(row 1000000 $KEY 0)")
[ -z "$got" ] && ok || bad "S3: a row of 0 must unarm project-triage, got '$got'"
got=$(kill_with "$(row 1000000 lib.context-kill.context_kill_tokens_box_chat 700000)" chat someproj)
[ "$got" = 700000 ] && ok || bad "S3: a row must arm the unarmed box-chat, got '${got:-<unbounded>}'"
# S4. OUTAGE: the worker cannot answer. With a cached row, the cached row; with
#     nothing cached, the MANIFEST number — never unbounded.
got=$(kill_with "$(row 1 $KEY 3000000)")
[ "$got" = 3000000 ] && ok || bad "S4: worker down, cached row 3,000,000 — resolved '${got:-<unbounded>}'"
got=$(kill_with none)
{ [ -n "$got" ] && [ "$got" = "$PT" ]; } \
  && ok || bad "S4: worker down, no cache — resolved '${got:-<unbounded>}', want the manifest's $PT"
# S5. a row that is not a whole number is ignored: the manifest stands
got=$(kill_with "$(row 1000000 $KEY lots)")
[ "$got" = "$PT" ] && ok || bad "S5: a non-numeric row resolved '${got:-<unbounded>}', want the manifest's $PT"
# S6. a row for ANOTHER lane leaves this one on the manifest; pins still win
got=$(kill_with "$(row 1000000 lib.context-kill.context_kill_tokens_build_fix 1)")
[ "$got" = "$PT" ] && ok || bad "S6: build-fix's row moved project-triage to '${got:-<unbounded>}'"
got=$(kill_with "$(row 1000000 $KEY 9000000)" triage alert-triage)
[ "$got" = 400000 ] && ok || bad "S6: project-triage's row reached the pinned alert-triage lane: '$got'"

# S7. end to end: a real triage shard under a fresh row is killed at the ROW's
#     number — a session the manifest (2.7M) lets finish.
: > "$T/logs/cost.csv"; : > "$T/logs/ALERTS.log"; : > "$T/logs/shardproj.log"
scratch_rm "$T/state/lane-gate"
row 1000000 $KEY 1000000 > "$T/state/settings-cache.json"
shard BH-7 STUB_ENTRIES=10 STUB_TOKENS=135000 STUB_HOLD=4 LANE_REGISTRY="$REG" LANE_GATE_NOW=1000000
grep -q 'CONTEXT KILL: triage/shardproj.* against ceiling 1000000 ' "$T/logs/ALERTS.log" \
  && ok || bad "S7: the shard was not killed at the row's 1,000,000: $(grep 'CONTEXT KILL' "$T/logs/ALERTS.log")"
rm -f "$T/state/settings-cache.json"

echo "context-kill-lanes.bh-2538-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

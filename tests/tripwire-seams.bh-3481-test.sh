#!/bin/bash
# tests/tripwire-seams.bh-3481-test.sh — the live-cost and tripwire SEAMS
# (BH-3481.0 / BH-3497): two stub libs and their call sites in bin/agent-call.sh
# and run-build's CC() dispatcher.
#
# The stubs answer "off" and never trip, so the product behaviour is unchanged.
# Since BH-6705 neither $BUILD/TRIPWIRE nor tw_check_build stops a call or a
# build (T15, CC0, CC2, CC3); $OUT.tripwire still stops a session's ladder (LS).
# What this suite pins is that the call sites are WIRED: with the stubs a call
# is the call it always was, and with a marker file or a fake lib in place the
# seam does what the contract says. Every agent-call case drives the REAL
# bin/agent-call.sh (or a copy of the real bin/ with one lib swapped) against
# fake vendor CLIs; every CC case runs the REAL CC() extracted from the
# flattened pipeline. Assertions are on artifacts: rc, $OUT, cost rows, the
# vendor order sink, ALERTS.log, marker files.
#
# Run from anywhere: tests/tripwire-seams.bh-3481-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# =============================================================================
# S0 — the two libs source cleanly; the cost-live stubs answer their defaults and
# the tripwire (filled by BH-3501) answers its real contract on an empty build
# =============================================================================
mkdir -p "$T/s0b" "$T/s0t"
S0=$(HARNESS="$T" bash -c '
  set -euo pipefail
  . "$1"; . "$2"
  for f in cost_live_on cost_live_row cost_live_push cost_live_meter cost_live_boundary_push \
           tw_expected tw_eval tw_trip tw_paused tw_check_build; do
    declare -F "$f" >/dev/null || echo "undefined:$f"
  done
  rc=0; cost_live_on || rc=$?; echo "on=$rc:$CL_OFF"
  rc=0; out=$(cost_live_row box sid line) || rc=$?; echo "row=$rc:$out"
  rc=0; cost_live_push "{}" || rc=$?; echo "push=$rc"
  rc=0; cost_live_meter 1 sid /tmp || rc=$?; echo "meter=$rc"
  rc=0; cost_live_boundary_push || rc=$?; echo "bpush=$rc"
  rc=0; out=$(tw_expected p "$3") || rc=$?; echo "expected=$rc:$out"
  printf "eval=%s\n" "$(tw_eval x.csv 1 1 3 2)"
  rc=0; tw_trip p k "$4" "v" || rc=$?; echo "trip=$rc"
  rc=0; tw_paused p k || rc=$?; echo "paused=$rc"
  rc=0; out=$(tw_check_build p k "$3" 0) || rc=$?; echo "check=$rc:$out"
' _ "$DIR/bin/lib/cost-live.sh" "$DIR/bin/lib/build-tripwire.sh" "$T/s0b" "$T/s0t" 2>&1); S0RC=$?
[ "$S0RC" = 0 ] && ok || bad "S0 sourcing/driving the stubs under set -eu failed rc=$S0RC: $S0"
grep -q '^undefined:' <<<"$S0" && bad "S0 functions missing: $(grep '^undefined:' <<<"$S0" | tr '\n' ' ')" || ok
# BH-3500 filled the bodies: off here (no secret, or the sandbox) with a reason.
grep -qxE 'on=1:[a-z=-]+' <<<"$S0" && ok || bad "S0 cost_live_on is not rc 1 with a CL_OFF reason: $S0"
grep -qx 'row=1:' <<<"$S0" && ok || bad "S0 cost_live_row stub is not rc 1 + silent"
grep -qx 'push=0' <<<"$S0" && grep -qx 'meter=0' <<<"$S0" && grep -qx 'bpush=0' <<<"$S0" \
  && ok || bad "S0 cost_live_push/meter/boundary_push are not rc 0: $S0"
# BH-3501 filled the tripwire bodies: these pin the real contract on an empty
# build dir (no cost.csv, no jobs-client under this HARNESS), not the stubs.
grep -qxE 'expected=0:[0-9]+(\.[0-9]+)?' <<<"$S0" && ok || bad "S0 tw_expected is not rc 0 + a number: $S0"
grep -q "^$(printf 'eval=ok\tspend=1.00\t')" <<<"$S0" && ok || bad "S0 tw_eval on no csv did not print ok<TAB>spend=1.00: $S0"
grep -qx 'trip=0' <<<"$S0" && grep -qx 'paused=2' <<<"$S0" && ok || bad "S0 tw_trip rc 0 / tw_paused rc 2 (no client = unreadable) wrong: $S0"
grep -qx 'check=1:' <<<"$S0" && ok || bad "S0 tw_check_build on a dir with no cost.csv is not rc 1 + silent: $S0"
[ -e "$T/s0b/TRIPWIRE" ] && bad "S0 tw_check_build wrote a TRIPWIRE marker" || ok
S0N=$(HARNESS= H= bash -c '. "$1"; cost_live_on; echo "$?:$CL_OFF"' _ "$DIR/bin/lib/cost-live.sh" 2>&1)
[ "$S0N" = "1:no-root" ] && ok || bad "S0 cost_live_on with no root: '$S0N', want 1:no-root"

# =============================================================================
# the agent-call fixture
# =============================================================================
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/builds"
echo '{"lanes":[]}' > "$T/budgets.json"
# claude: records itself, optionally writes the tripwire marker for the $OUT it
# was told about, then answers or fails.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
if [ -n "${TW_OUT:-}" ]; then printf '%s\n' "${TW_LINE:-spend 12.40 3.10}" > "$TW_OUT.tripwire"; fi
case "${CLAUDE_RESULT:-ok}" in
  fail) echo "vendor error" >&2; exit 1 ;;
  *)    echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'; exit 0 ;;
esac
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$ORDER_SINK"
echo "grok answered"
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex
for arg in "$@"; do
  case "$arg" in
    *model_provider*openrouter*) provider=openrouter ;;
    *model_provider*fireworks*) provider=fireworks ;;
  esac
done
echo "$provider" >> "$ORDER_SINK"
echo "$provider answered"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

reset() {
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  rm -f "$T/logs/cost.csv"; rm -rf "$T/builds" "$T/other" "$T/cl"; mkdir -p "$T/builds" "$T/other" "$T/cl"
}
# call <agent-call path> <out> [VAR=VAL ...] -> prints the rc; stderr to $T/err
call() {
  local ac="$1" out="$2"; shift 2
  ( unset HARNESS_TICKET AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID
    export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" CL_SINK="$T/cl" \
           CALL_GUARD=0 CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 CLAUDE_RESULT=ok \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           IRON_LAW_LANES=none COST_TRANSCRIPT_ROWS=1 CONTEXT_BUDGETS="$T/budgets.json" "$@"
    cd "$T" && bash "$ac" eval testproj claude-fable-5-1 60 "$out" "hello" >/dev/null 2>"$T/err" )
  echo $?
}
AC="$DIR/bin/agent-call.sh"
# The survival lanes, all ready: grok tier-2, OpenRouter always, Fireworks.
LADDER=(LADDER_TIER2_GROK=1 OPENROUTER_API_KEY=k OPENROUTER_FALLBACK=always FIREWORKS_API_KEY=k)

# =============================================================================
# NOOP — the stub libs: a normal call is the call it always was
# =============================================================================
reset; mkdir -p "$T/builds/n0"
R=$(call "$AC" "$T/builds/n0/execute-run.txt")
[ "$R" = 0 ] && ok || bad "NOOP rc=$R, want 0: $(cat "$T/err")"
[ "$(cat "$T/order")" = claude ] && ok || bad "NOOP vendor order '$(tr '\n' ' ' < "$T/order")', want claude"
[ "$(cat "$T/builds/n0/execute-run.txt" 2>/dev/null)" = "the answer" ] && ok || bad "NOOP output altered"
NR=$(grep -c ',eval,claude,' "$T/builds/n0/cost.csv" 2>/dev/null)
[ "$NR" = 1 ] && ok || bad "NOOP build cost rows: $NR, want 1"
grep -q 'tripwire:' <<<"$(grep ',eval,claude,' "$T/builds/n0/cost.csv")" && bad "NOOP row carries a tripwire note" || ok
[ -e "$T/builds/n0/execute-run.txt.tripwire" ] || [ -e "$T/builds/n0/TRIPWIRE" ] \
  && bad "NOOP a tripwire marker was written by a normal call" || ok
grep -q 'command not found' "$T/err" && bad "NOOP stderr: $(cat "$T/err")" || ok

# NOOP with the libs ABSENT: a copy of bin/ without either lib (the fallback
# stubs) still runs the call, and no seam function is missing.
rm -rf "$T/nolib"; mkdir -p "$T/nolib"; cp -R "$DIR/bin" "$T/nolib/bin"
rm -f "$T/nolib/bin/lib/cost-live.sh" "$T/nolib/bin/lib/build-tripwire.sh"
reset; mkdir -p "$T/builds/n1"
R=$(call "$T/nolib/bin/agent-call.sh" "$T/builds/n1/execute-run.txt")
[ "$R" = 0 ] && [ "$(cat "$T/order")" = claude ] && ok || bad "NOOP-absent rc=$R order=$(cat "$T/order")"
grep -q 'command not found' "$T/err" && bad "NOOP-absent a seam function has no fallback: $(grep 'command not found' "$T/err")" || ok
[ "$(grep -c ',eval,claude,' "$T/builds/n1/cost.csv" 2>/dev/null)" = 1 ] && ok || bad "NOOP-absent no build cost row"

# =============================================================================
# NOOP-ON — a fake cost-live lib that says ON: the CLI is backgrounded, the
# live meter runs with this call's session id and is gone after the call, and
# the boundary push fires once per call AFTER the row exists.
# =============================================================================
rm -rf "$T/on"; mkdir -p "$T/on"; cp -R "$DIR/bin" "$T/on/bin"
cat > "$T/on/bin/lib/cost-live.sh" <<'EOF'
cost_live_on() { return 0; }
cost_live_row() { return 1; }
cost_live_push() { return 0; }
cost_live_meter() {
  printf '%s %s %s %s\n' "$BASHPID" "$1" "$2" "$3" > "$CL_SINK/meter"
  while :; do sleep 0.2; done
}
cost_live_boundary_push() {
  local f="$COST"
  case "$OUT" in */builds/*/*) f="$(dirname "$OUT")/cost.csv" ;; esac
  printf '%s %s\n' "$(grep -c . "$f" 2>/dev/null || echo 0)" "$OUT" >> "$CL_SINK/push"
}
EOF
reset; mkdir -p "$T/builds/x"
R=$(call "$T/on/bin/agent-call.sh" "$T/builds/x/execute-run.txt")
[ "$R" = 0 ] && ok || bad "NOOP-ON rc=$R: $(cat "$T/err")"
[ "$(cat "$T/builds/x/execute-run.txt" 2>/dev/null)" = "the answer" ] && ok || bad "NOOP-ON output altered"
if [ -s "$T/cl/meter" ]; then
  ok
  read -r MPID MCLI MSID MCWD < "$T/cl/meter"
  SROW=$(grep ',eval,claude,' "$T/builds/x/cost.csv" | tail -1 | cut -d, -f17)
  [ -n "$MSID" ] && [ "$MSID" = "$SROW" ] && ok || bad "NOOP-ON meter sid '$MSID' is not the row's session '$SROW'"
  [ -n "$MCLI" ] && [ "$MCLI" -gt 1 ] 2>/dev/null && ok || bad "NOOP-ON meter got no cli pid: '$MCLI'"
  [ "$MCWD" = "$T" ] && ok || bad "NOOP-ON meter cwd '$MCWD', want $T"
  sleep 0.3
  kill -0 "$MPID" 2>/dev/null && { bad "NOOP-ON the live meter ($MPID) outlived the call"; kill "$MPID" 2>/dev/null; } || ok
else
  bad "NOOP-ON cost_live_meter never ran (the CLI was not backgrounded for live cost)"
fi
# no session id -> CLI still backgrounded, no live meter
rm -f "$T/cl/meter"; mkdir -p "$T/builds/y"
R=$(call "$T/on/bin/agent-call.sh" "$T/builds/y/execute-run.txt" COST_TRANSCRIPT_ROWS=0)
[ "$R" = 0 ] && ok || bad "NOOP-ON no-sid rc=$R"
[ -e "$T/cl/meter" ] && bad "NOOP-ON the live meter ran with no session id" || ok
# boundary push: one build call (above: x, y) + one non-build call
R=$(call "$T/on/bin/agent-call.sh" "$T/other/triage-out.txt")
[ "$R" = 0 ] && ok || bad "NOOP-ON non-build rc=$R"
[ "$(grep -c . "$T/cl/push" 2>/dev/null)" = 3 ] && ok || bad "NOOP-ON boundary pushes: $(grep -c . "$T/cl/push" 2>/dev/null), want 3 (x, y, other): $(cat "$T/cl/push" 2>/dev/null)"
PX=$(grep "builds/x/execute-run.txt\$" "$T/cl/push" 2>/dev/null | cut -d' ' -f1)
[ -n "$PX" ] && [ "$PX" -ge 2 ] && ok || bad "NOOP-ON the build push ran before the build row was teed (cost.csv lines at push: '${PX:-none}')"
PO=$(grep "other/triage-out.txt\$" "$T/cl/push" 2>/dev/null | cut -d' ' -f1)
PN=$(grep -c ',eval,claude,' "$T/logs/cost.csv" 2>/dev/null)
[ -n "$PO" ] && [ "$PO" -ge "$PN" ] && [ "$PN" = 3 ] && ok || bad "NOOP-ON the non-build push ran before its row (lines at push '${PO:-none}', claude rows now $PN)"

# =============================================================================
# T15 — $BUILD/TRIPWIRE no longer refuses the call (BH-6705: the tripwire
# never stops a build); a leftover marker is ignored and the call is made
# =============================================================================
reset; mkdir -p "$T/builds/b15"
echo "spend 40.00 over 3x expected" > "$T/builds/b15/TRIPWIRE"
R=$(call "$AC" "$T/builds/b15/plan-run.txt")
[ "$R" = 0 ] && ok || bad "T15 rc=$R, want 0"
[ "$(cat "$T/builds/b15/plan-run.txt" 2>/dev/null)" = "the answer" ] \
  && ok || bad "T15 \$OUT: $(head -1 "$T/builds/b15/plan-run.txt" 2>/dev/null)"
[ "$(cat "$T/order")" = claude ] && ok || bad "T15 claude was not called: $(tr '\n' ' ' < "$T/order")"
grep -q 'TRIPWIRE REFUSED' "$T/logs/failovers.log" && bad "T15 a TRIPWIRE REFUSED failovers.log line" || ok
grep -q 'refused:tripwire' "$T/logs/cost.csv" 2>/dev/null && bad "T15 a refused:tripwire cost row" || ok
# T15-neg-a: same shape, no TRIPWIRE -> proceeds
reset; mkdir -p "$T/builds/b16"
R=$(call "$AC" "$T/builds/b16/plan-run.txt")
[ "$R" = 0 ] && [ "$(cat "$T/order")" = claude ] && ok || bad "T15-neg-a rc=$R order=$(cat "$T/order")"
# T15-neg-b: OUT outside */builds/*/* with a stray TRIPWIRE beside it -> proceeds
reset; echo "stray" > "$T/other/TRIPWIRE"
R=$(call "$AC" "$T/other/out")
[ "$R" = 0 ] && [ "$(cat "$T/order")" = claude ] && ok || bad "T15-neg-b rc=$R order=$(cat "$T/order") (a non-build call was refused)"

# =============================================================================
# LS — $OUT.tripwire stops the ladder like a context kill
# =============================================================================
# Control first: the same failing claude with NO tripwire does engage the
# ladder here, so the stop below is the tripwire's doing and not the fixture's.
reset; mkdir -p "$T/builds/c"
R=$(call "$AC" "$T/builds/c/execute-run.txt" "${LADDER[@]}" CLAUDE_RESULT=fail)
[ "$(grep -c . "$T/order")" -ge 2 ] && ok || bad "LS control: the ladder did not engage on a plain failure (order: $(tr '\n' ' ' < "$T/order")) — the LS case below would prove nothing"
reset; mkdir -p "$T/builds/x"
OUT="$T/builds/x/execute-run.txt"
R=$(call "$AC" "$OUT" "${LADDER[@]}" CLAUDE_RESULT=fail TW_OUT="$OUT")
[ "$R" != 0 ] && ok || bad "LS a tripwire-stopped session returned rc 0"
[ "$(cat "$T/order")" = claude ] && ok || bad "LS the ladder went on after a tripwire stop: $(tr '\n' ' ' < "$T/order")"
LROW=$(grep ',eval,claude,' "$T/builds/x/cost.csv" 2>/dev/null | tail -1)
[ -n "$LROW" ] && ok || bad "LS no cost row for the stopped session"
grep -q 'tripwire:spend' <<<"$LROW" && ok || bad "LS the row's note does not say tripwire:spend: $LROW"
tail -1 "$OUT" 2>/dev/null | grep -q '^TRIPWIRE: eval/testproj' && ok || bad "LS last line of \$OUT: $(tail -1 "$OUT" 2>/dev/null)"
grep -qE 'BUDGET STOP|KILLED' "$T/logs/ALERTS.log" && bad "LS ALERTS: $(cat "$T/logs/ALERTS.log")" || ok
grep -q 'TRIPWIRE' "$T/logs/failovers.log" && ok || bad "LS no TRIPWIRE policy line in failovers.log"
# LS-esc: with a fable -> opus claude ladder in the resolver's box cache (the
# worker is down in this fixture), a plain failure escalates to opus; a
# tripwire stop does not buy the next model.
mkdir -p "$T/state/model-routes"
printf '0\tclaude-fable-5-1\tclaude\n1\tclaude-opus-5-5\tclaude\n' > "$T/state/model-routes/claude.ladder@testproj.tsv"
reset; mkdir -p "$T/builds/x"
R=$(call "$AC" "$OUT" CLAUDE_RESULT=fail)
[ "$(cat "$T/order")" = "$(printf 'claude\nclaude')" ] && ok || bad "LS-esc control: a plain failure did not escalate fable -> opus (order: $(tr '\n' ' ' < "$T/order")) — LS-esc below would prove nothing"
reset; mkdir -p "$T/builds/x"
R=$(call "$AC" "$OUT" CLAUDE_RESULT=fail TW_OUT="$OUT")
[ "$R" != 0 ] && [ "$(cat "$T/order")" = claude ] && ok || bad "LS-esc a tripwire stop escalated to the next model (rc=$R order: $(tr '\n' ' ' < "$T/order"))"
rm -f "$T/state/model-routes/claude.ladder@testproj.tsv"
# a tripwire on an rc-0 session is still a stop (the marker is authoritative)
reset; mkdir -p "$T/builds/x"
R=$(call "$AC" "$OUT" "${LADDER[@]}" TW_OUT="$OUT")
[ "$R" != 0 ] && [ "$(cat "$T/order")" = claude ] && ok || bad "LS-rc0 rc=$R order=$(tr '\n' ' ' < "$T/order") — a tripwire kill that exited 0 read as success"
# a stale marker from an earlier call with the same OUT does not stop a clean one
reset; mkdir -p "$T/builds/x"; echo "spend old" > "$OUT.tripwire"
R=$(call "$AC" "$OUT")
[ "$R" = 0 ] && [ "$(cat "$OUT")" = "the answer" ] && ok || bad "LS-stale a stale \$OUT.tripwire stopped a clean call (rc=$R)"

# =============================================================================
# CC0..CC3 — the real CC() dispatcher
# =============================================================================
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
python3 - "$RB_ALL" "$T/cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
PY
[ -s "$T/cc.sh" ] && ok || bad "CC could not extract CC() from the pipeline"
mkdir -p "$T/h/bin"
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
touch "$SINK/agent-call"
[ -n "${WRITE_TW:-}" ] && echo "spend 9.99 after" > "$BUILD/TRIPWIRE"
exit "${AC_RC:-0}"
STUB
chmod +x "$T/h/bin/agent-call.sh"
# cc <case> [VAR=VAL ...] -> prints CC's rc; sinks in $T/cc/<case>/
cc() {
  local c="$1"; shift
  rm -rf "$T/cc/$c"; mkdir -p "$T/cc/$c/build"
  [ -n "${PRE_TW:-}" ] && echo "$PRE_TW" > "$T/cc/$c/build/TRIPWIRE"
  ( export SINK="$T/cc/$c" BUILD="$T/cc/$c/build" "$@"
    bash -c '
      set -uo pipefail
      HARNESS="'"$T"'/h"; PROJECT=demo-os; KEY=DEMO-1; CG_ORIENT=x
      BB() { printf "%s|%s\n" "$1" "${6:-}" >> "$SINK/bb"; }
      RESULT() { printf "%s\n" "$*" >> "$SINK/result"; }
      [ -n "${TWLIB:-}" ] && . "$TWLIB"
      . "'"$T"'/cc.sh"
      CC execute model 60 "$BUILD/execute-run.txt" "PROMPT"
      echo "returned $?" > "$SINK/returned"' )
  echo $?
}
# CC0: a leftover TRIPWIRE -> ignored (BH-6705): agent-call runs, its rc passes through
R=$(PRE_TW="spend 40.00 before" cc cc0 AC_RC=7)
[ "$R" = 0 ] && [ "$(cat "$T/cc/cc0/returned" 2>/dev/null)" = "returned 7" ] && ok \
  || bad "CC0 CC did not hand back agent-call's rc 7 (subshell rc=$R, $(cat "$T/cc/cc0/returned" 2>/dev/null))"
[ -e "$T/cc/cc0/agent-call" ] && ok || bad "CC0 agent-call did not run with a leftover TRIPWIRE"
[ -e "$T/cc/cc0/result" ] || [ -e "$T/cc/cc0/bb" ] && bad "CC0 RESULT/BB: $(cat "$T/cc/cc0/result" "$T/cc/cc0/bb" 2>/dev/null)" || ok
# CC1: no TRIPWIRE, the real stub lib loaded -> agent-call's rc passes through
R=$(cc cc1 AC_RC=7 TWLIB="$DIR/bin/lib/build-tripwire.sh")
[ "$R" = 0 ] && [ "$(cat "$T/cc/cc1/returned" 2>/dev/null)" = "returned 7" ] && ok \
  || bad "CC1 CC did not hand back agent-call's rc 7 (subshell rc=$R, $(cat "$T/cc/cc1/returned" 2>/dev/null))"
[ -e "$T/cc/cc1/agent-call" ] && ok || bad "CC1 agent-call did not run"
[ -e "$T/cc/cc1/result" ] || [ -e "$T/cc/cc1/bb" ] && bad "CC1 a RESULT/BB was written with no tripwire" || ok
# CC2: a TRIPWIRE written during the call -> ignored, CC returns agent-call's rc
R=$(cc cc2 WRITE_TW=1 AC_RC=7)
[ "$R" = 0 ] && [ -e "$T/cc/cc2/agent-call" ] && [ "$(cat "$T/cc/cc2/returned" 2>/dev/null)" = "returned 7" ] \
  && ok || bad "CC2 subshell rc=$R $(cat "$T/cc/cc2/returned" 2>/dev/null) (want returned 7 after the call)"
[ -e "$T/cc/cc2/result" ] || [ -e "$T/cc/cc2/bb" ] && bad "CC2 RESULT/BB: $(cat "$T/cc/cc2/result" "$T/cc/cc2/bb" 2>/dev/null)" || ok
# CC3: a tw_check_build that answers rc 0 and writes TRIPWIRE -> CC still calls
# (it reads no answer from the check) and returns agent-call's rc
cat > "$T/tw-trips.sh" <<'EOF'
tw_check_build() { echo "rule-x $1 $2" > "$3/TRIPWIRE"; echo noise; touch "$SINK/tw-called"; return 0; }
EOF
R=$(cc cc3 TWLIB="$T/tw-trips.sh" AC_RC=7)
[ "$R" = 0 ] && [ "$(cat "$T/cc/cc3/returned" 2>/dev/null)" = "returned 7" ] && ok \
  || bad "CC3 subshell rc=$R $(cat "$T/cc/cc3/returned" 2>/dev/null), want returned 7"
[ -e "$T/cc/cc3/tw-called" ] && ok || bad "CC3 CC did not run the tripwire check before the call"
[ -e "$T/cc/cc3/agent-call" ] && ok || bad "CC3 agent-call did not run after the check"
[ -e "$T/cc/cc3/result" ] || [ -e "$T/cc/cc3/bb" ] && bad "CC3 RESULT/BB: $(cat "$T/cc/cc3/result" "$T/cc/cc3/bb" 2>/dev/null)" || ok

echo "tripwire-seams.bh-3481-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/build-tripwire-alert-only.bh-6705-test.sh — the build tripwire alerts
# and never stops a build (BH-6705, the operator 2026-10-14: "It should never stop a
# build").
#
#   A1  a build past BUILD_TRIPWIRE_MULT x expected (or past the repeat max)
#       gets one critical page, one `alerted` ledger row and
#       $BUILD/tripwire-alert.txt; tw_check_build answers rc 1 + silent and
#       never writes $BUILD/TRIPWIRE.
#   A2  the launch guard (`tripwire paused skip`, lifted from the flattened
#       pipeline) builds a ticket with a leftover `paused` row, with one line.
#   A3  the real CC() never ends a build on $BUILD/TRIPWIRE.
#   A4  the real bin/agent-call.sh never refuses a call on $BUILD/TRIPWIRE.
#   A5  BUILD_TRIPWIRE defaults to 0 (registry and lib fallback).
#
# Run from anywhere: tests/build-tripwire-alert-only.bh-6705-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=1000000
TAB=$'\t'

# ---------- fixture: a scratch HARNESS with the real lib closure + stubs -----
mkdir -p "$T/h/state" "$T/h/logs" "$T/b" "$T/noenv"
( cd "$DIR" && scratch_install_closure bin/lib/build-tripwire.sh "$T/h" >/dev/null ) \
  || { echo "cannot install the build-tripwire closure"; exit 1; }
TWLIB="$T/h/bin/lib/build-tripwire.sh"
cat > "$T/h/bin/jobs-client.sh" <<'STUB'
#!/bin/bash
[ "${BASH_SOURCE[0]}" != "$0" ] && return 0
echo "$*" >> "$TW_SINK/ledger.log"
if [ "${1:-}" = ledger-get ]; then printf '%s\n' "${JC_GET:-}"; exit "${JC_GET_RC:-0}"; fi
exit "${JC_RC:-0}"
STUB
cat > "$T/h/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$TW_SINK/alert.log"
STUB
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
echo "$1 $2" >> "$TW_SINK/ac.log"
[ -n "${WRITE_TW:-}" ] && echo "spend 9.99 after" > "$BUILD/TRIPWIRE"
exit "${AC_RC:-0}"
STUB
chmod +x "$T/h/bin/jobs-client.sh" "$T/h/bin/lane-alert.sh" "$T/h/bin/agent-call.sh"
printf 'default 100 5\n' > "$T/caps.conf"
"$DIR/bin/lanes-build.sh" --to "$T/lanes.json" >/dev/null 2>&1 || { echo "cannot render the lane registry"; exit 1; }
unset JOBS_URL HARNESS_SECRET LANE_GATE_DISABLE SESSION_ID
for v in ${!BUILD_TRIPWIRE@}; do unset "$v"; done
export COST_CAPS_CONF="$T/caps.conf" LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW" \
       HARNESS_ENV_DIR="$T/noenv" TW_SINK="$T"

HDR=$(. "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "${COST_ROW_HDR:-}")
[ -n "$HDR" ] || { echo "cannot read COST_ROW_HDR"; exit 1; }
# mkbuild <name> <S|M|L|XL> [stage:cost:fp ...] -> the dir
mkbuild() {
  local d="$T/b/$1" sz="$2" r st c fp; shift 2
  scratch_rm "$d" || return 1; mkdir -p "$d"
  printf '# plan\n\nSIZE: %s\n' "$sz" > "$d/plan.md"
  printf '%s\n' "$HDR" > "$d/cost.csv"
  for r in "$@"; do
    IFS=: read -r st c fp <<<"$r"
    awk -v st="$st" -v c="$c" -v fp="$fp" 'BEGIN{
      for(i=1;i<=26;i++) f[i]=""; f[1]="2026-10-14T20:00:00Z"; f[3]="tproj"
      f[4]=st; f[13]=c; f[26]=fp; s=f[1]; for(i=2;i<=26;i++) s=s "," f[i]; print s }' >> "$d/cost.csv"
  done
  printf '%s' "$d"
}
tw() { HARNESS="$T/h" bash -c 'set -uo pipefail; . "$0" || exit 99; "$@"' "$TWLIB" "$@"; }
sinks_clear() { : > "$T/ledger.log"; : > "$T/alert.log"; : > "$T/ac.log"; }
nlines() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# ============================== A1: alert, never stop ========================
B=$(mkbuild a1 M execute:510:)
sinks_clear; R=0; O=$(BUILD_TRIPWIRE=1 tw tw_check_build tproj BH-1 "$B" 0) || R=$?
[ "$R" = 1 ] && [ -z "$O" ] && ok || bad "A1 5.1x: tw_check_build rc=$R out='$O', want rc 1 + silent"
[ -e "$B/TRIPWIRE" ] && bad "A1 5.1x wrote \$BUILD/TRIPWIRE" || ok
case "$(head -1 "$B/tripwire-alert.txt" 2>/dev/null)" in
  "trip${TAB}spend${TAB}"*) ok ;; *) bad "A1 tripwire-alert.txt line 1: '$(head -1 "$B/tripwire-alert.txt" 2>/dev/null)'" ;;
esac
grep -qx 'alert_row: written' "$B/tripwire-alert.txt" 2>/dev/null && ok || bad "A1 tripwire-alert.txt lacks 'alert_row: written'"
grep -q '^release:' "$B/tripwire-alert.txt" 2>/dev/null && bad "A1 tripwire-alert.txt still has a release: line" || ok
[ "$(nlines "$T/alert.log")" = 1 ] && ok || bad "A1 alert lines $(nlines "$T/alert.log"), want 1"
grep -q -- '--severity critical --id tripwire:tproj:BH-1:a1 build-tripwire ' "$T/alert.log" \
  && grep -q 'alert only' "$T/alert.log" && grep -q 'alert_row=written' "$T/alert.log" \
  && ok || bad "A1 alert text: $(cat "$T/alert.log")"
[ "$(grep -cx 'ledger-put build-tripwire tproj BH-1 alerted' "$T/ledger.log")" = 1 ] && ok || bad "A1 ledger: $(cat "$T/ledger.log")"
grep -q 'paused' "$T/ledger.log" && bad "A1 wrote a paused ledger row" || ok
# a second check on the tripped dir: no second page, no second row
R=0; O=$(BUILD_TRIPWIRE=1 tw tw_check_build tproj BH-1 "$B" 0) || R=$?
[ "$R" = 1 ] && [ -z "$O" ] && [ "$(nlines "$T/alert.log")" = 1 ] && [ "$(nlines "$T/ledger.log")" = 1 ] \
  && ok || bad "A1 second check rc=$R out='$O' alerts=$(nlines "$T/alert.log") ledger=$(nlines "$T/ledger.log")"
# under (4.9x) and exactly at (5.0x, the rule is strict >) the threshold: nothing
for c in 490 500; do
  B=$(mkbuild "a1-$c" M "execute:$c:")
  sinks_clear; R=0; O=$(BUILD_TRIPWIRE=1 tw tw_check_build tproj BH-1 "$B" 0) || R=$?
  [ "$R" = 1 ] && [ -z "$O" ] && [ ! -s "$T/alert.log" ] && [ ! -s "$T/ledger.log" ] && [ ! -e "$B/tripwire-alert.txt" ] \
    && ok || bad "A1 at $c: rc=$R alerts=$(nlines "$T/alert.log") ledger=$(nlines "$T/ledger.log")"
done
# the repeat rule: four paid rows on one fp alert once, three do not
B=$(mkbuild a1-r4 M fix:1:z fix:1:z fix:1:z fix:1:z)
sinks_clear; R=0; O=$(BUILD_TRIPWIRE=1 tw tw_check_build tproj BH-1 "$B" 0) || R=$?
[ "$R" = 1 ] && [ -z "$O" ] && [ "$(nlines "$T/alert.log")" = 1 ] && [ ! -e "$B/TRIPWIRE" ] \
  && grep -q "^trip${TAB}repeat${TAB}" "$B/tripwire-alert.txt" 2>/dev/null \
  && ok || bad "A1 repeat x4: rc=$R alerts=$(nlines "$T/alert.log") TRIPWIRE=$([ -e "$B/TRIPWIRE" ] && echo yes || echo no)"
B=$(mkbuild a1-r3 M fix:1:z fix:1:z fix:1:z)
sinks_clear; R=0; BUILD_TRIPWIRE=1 tw tw_check_build tproj BH-1 "$B" 0 >/dev/null || R=$?
[ "$R" = 1 ] && [ ! -s "$T/alert.log" ] && ok || bad "A1 repeat x3: rc=$R alerts=$(nlines "$T/alert.log")"
# the ledger write fails: said in the page and the file, the build still runs
B=$(mkbuild a1-f M execute:510:)
sinks_clear; R=0; O=$(BUILD_TRIPWIRE=1 JC_RC=1 tw tw_check_build tproj BH-1 "$B" 0) || R=$?
[ "$R" = 1 ] && grep -q 'alert_row=FAILED' "$T/alert.log" && grep -qx 'alert_row: FAILED' "$B/tripwire-alert.txt" 2>/dev/null \
  && ok || bad "A1 ledger failure: rc=$R alert='$(cat "$T/alert.log")'"

# ============================== A2: the launch guard ==========================
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }
awk '/^# >>> tripwire paused skip/{f=1} f{print} /^# <<< tripwire paused skip/{exit}' "$RB_ALL" > "$T/guard.sh"
[ -s "$T/guard.sh" ] && ok || bad "A2 could not lift the 'tripwire paused skip' block"
mkdir -p "$T/gb"
guard() { # guard <ledger-rc> <status> -> stdout of the block + CONTINUED
  rm -f "$T/gres" "$T/qput" "$T/gb/pipeline.log"
  LRC="$1" LST="$2" HARNESS="$T/h" BUILD="$T/gb" PROJECT=tproj KEY=BH-2 bash -c '
    STAMP() { echo 2026-10-14T20:00:00Z; }
    RESULT() { echo "$*" > "$TW_SINK/gres"; }
    queue_put() { : > "$TW_SINK/qput"; }
    job_ledger_get() { [ "$1" = build-tripwire ] && [ "$2" = "tproj BH-2" ] || return 2; [ "$LRC" = 0 ] && printf "%s" "$LST"; return "$LRC"; }
    . "$0"
    echo CONTINUED
    queue_put' "$T/guard.sh" 2>/dev/null
}
LEFT='leftover paused row for BH-2 ignored'
R=0; O=$(guard 0 paused) || R=$?
case "$O" in *CONTINUED*) ok ;; *) bad "A2 paused: the guard did not continue (rc=$R)" ;; esac
[ -e "$T/qput" ] && ok || bad "A2 paused: queue_put did not run"
[ -e "$T/gres" ] && bad "A2 paused: RESULT written: $(cat "$T/gres")" || ok
[ "$(grep -c "$LEFT" "$T/gb/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "A2 paused: want 1 '$LEFT' line, pipeline.log: $(cat "$T/gb/pipeline.log" 2>/dev/null)"
for st in released alerted; do
  O=$(guard 0 "$st")
  case "$O" in *CONTINUED*) ok ;; *) bad "A2 $st did not continue" ;; esac
  [ ! -e "$T/gres" ] && ! grep -q 'leftover paused' "$T/gb/pipeline.log" 2>/dev/null && ok || bad "A2 $st: a RESULT or a leftover line"
done
O=$(guard 2 "")
case "$O" in *CONTINUED*) ok ;; *) bad "A2 no row did not continue" ;; esac
grep -q 'leftover paused' "$T/gb/pipeline.log" 2>/dev/null && bad "A2 no row wrote a leftover line" || ok

# ============================== A3: the real CC() =============================
python3 - "$RB_ALL" "$T/cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
PY
[ -s "$T/cc.sh" ] && ok || bad "A3 could not extract CC()"
# cc <build> [VAR=VAL ...] -> prints the subshell rc; CC's own rc in $T/returned
cc() {
  local b="$1"; shift
  rm -f "$T/ac.log" "$T/bb.log" "$T/result" "$T/returned"
  ( export BUILD="$b" HARNESS="$T/h" "$@"
    bash -c '
      set -uo pipefail
      PROJECT=tproj; KEY=BH-3; CG_ORIENT=x
      BB() { echo "$*" >> "$TW_SINK/bb.log"; }
      RESULT() { echo "$*" >> "$TW_SINK/result"; }
      . "$0"; . "$1"
      CC execute model 60 "$BUILD/execute-run.txt" PROMPT
      echo "returned $?" > "$TW_SINK/returned"' "$TWLIB" "$T/cc.sh" )
  echo $?
}
# (a) a leftover TRIPWIRE before the call
B=$(mkbuild a3a M); echo "spend 40.00 before" > "$B/TRIPWIRE"; sinks_clear
R=$(cc "$B" AC_RC=7)
[ "$R" = 0 ] && [ "$(cat "$T/returned" 2>/dev/null)" = "returned 7" ] && ok || bad "A3a CC rc: subshell=$R $(cat "$T/returned" 2>/dev/null), want returned 7"
[ -s "$T/ac.log" ] && ok || bad "A3a agent-call did not run with a leftover TRIPWIRE"
[ -e "$T/result" ] || [ -e "$T/bb.log" ] && bad "A3a RESULT/BB written: $(cat "$T/result" "$T/bb.log" 2>/dev/null)" || ok
# (b) agent-call writes TRIPWIRE during the call
B=$(mkbuild a3b M); sinks_clear
R=$(cc "$B" AC_RC=7 WRITE_TW=1)
[ "$R" = 0 ] && [ "$(cat "$T/returned" 2>/dev/null)" = "returned 7" ] && [ -s "$T/ac.log" ] && ok \
  || bad "A3b CC rc: subshell=$R $(cat "$T/returned" 2>/dev/null)"
[ -e "$T/result" ] || [ -e "$T/bb.log" ] && bad "A3b RESULT/BB written: $(cat "$T/result" "$T/bb.log" 2>/dev/null)" || ok
# (c) a 5.1x build with the alert on: the call runs, one page, no terminal
B=$(mkbuild a3c M execute:510:); sinks_clear
R=$(cc "$B" AC_RC=7 BUILD_TRIPWIRE=1)
[ "$R" = 0 ] && [ "$(cat "$T/returned" 2>/dev/null)" = "returned 7" ] && [ -s "$T/ac.log" ] && ok \
  || bad "A3c CC rc: subshell=$R $(cat "$T/returned" 2>/dev/null) ac=$(nlines "$T/ac.log")"
[ "$(nlines "$T/alert.log")" = 1 ] && ok || bad "A3c alert lines $(nlines "$T/alert.log"), want 1"
[ -e "$T/result" ] || [ -e "$B/TRIPWIRE" ] && bad "A3c RESULT or TRIPWIRE written" || ok

# ============================== A4: the real agent-call =======================
mkdir -p "$T/ac/bin" "$T/ac/fakebin" "$T/ac/flags" "$T/ac/locks" "$T/ac/logs" "$T/ac/state" "$T/ac/builds/b4"
echo '{"lanes":[]}' > "$T/ac/budgets.json"
cat > "$T/ac/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$T/ac/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 7\n' > "$T/ac/fakebin/curl"
printf '#!/bin/bash\necho subscription\n' > "$T/ac/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/ac/bin/beat.sh"
chmod +x "$T/ac/fakebin/"* "$T/ac/bin/"*.sh
echo "spend 40.00 over 3x expected" > "$T/ac/builds/b4/TRIPWIRE"
: > "$T/ac/order"
( unset HARNESS_TICKET AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID
  export ORDER_SINK="$T/ac/order" PATH="$T/ac/fakebin:$PATH" HARNESS="$T/ac" HOME="$T/ac" \
         CALL_GUARD=0 CLAUDE_CODE_OAUTH_TOKEN=tok-fixture ANTHROPIC_API_KEY= \
         OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
         LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
         AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
         IRON_LAW_LANES=none COST_TRANSCRIPT_ROWS=1 CONTEXT_BUDGETS="$T/ac/budgets.json"
  cd "$T/ac" && bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5-1 60 "$T/ac/builds/b4/plan-run.txt" hello >/dev/null 2>"$T/ac/err" )
R=$?
[ "$R" = 0 ] && ok || bad "A4 agent-call rc=$R with TRIPWIRE in the build dir, want 0: $(head -3 "$T/ac/err")"
[ "$(cat "$T/ac/order")" = claude ] && ok || bad "A4 claude was not called: '$(tr '\n' ' ' < "$T/ac/order")'"
grep -q 'AGENT_CALL_REFUSED' "$T/ac/builds/b4/plan-run.txt" 2>/dev/null && bad "A4 \$OUT says AGENT_CALL_REFUSED" || ok
grep -q 'refused:tripwire' "$T/ac/logs/cost.csv" "$T/ac/builds/b4/cost.csv" 2>/dev/null && bad "A4 a refused:tripwire cost row" || ok
R=0; JC_GET=alerted tw tw_paused tproj BH-4 || R=$?
[ "$R" = 1 ] && ok || bad "A4 tw_paused on an alerted row rc=$R, want 1"

# ============================== A5: defaults ==================================
DF=$(jq '.libs[0].knobs[]|select(.env=="BUILD_TRIPWIRE").default' "$DIR/catalog/lanes.d/_lib.build-tripwire.json")
[ "$DF" = 0 ] && ok || bad "A5 registry default of BUILD_TRIPWIRE is '$DF', want 0"
grep -q '_TW_ON="${BUILD_TRIPWIRE:-0}"' "$DIR/bin/lib/build-tripwire.sh" && ok || bad "A5 the lib fallback is not \${BUILD_TRIPWIRE:-0}"
B=$(mkbuild a5 M execute:510:)
sinks_clear; R=0; O=$(tw tw_check_build tproj BH-5 "$B" 0) || R=$?
[ "$R" = 1 ] && [ ! -s "$T/alert.log" ] && [ ! -s "$T/ledger.log" ] && [ ! -e "$B/tripwire-alert.txt" ] && [ ! -e "$B/TRIPWIRE" ] \
  && ok || bad "A5 BUILD_TRIPWIRE unset at 5.1x: rc=$R alerts=$(nlines "$T/alert.log") ledger=$(nlines "$T/ledger.log")"
grep -qE '"\$b/TRIPWIRE"|ledger-put build-tripwire .*paused' <<<"$(grep -vE '^\s*#' "$DIR/bin/lib/build-tripwire.sh")" \
  && bad "A5 bin/lib/build-tripwire.sh still writes TRIPWIRE or a paused row" || ok
grep -q 'AGENT_CALL_REFUSED tripwire' "$DIR/bin/agent-call.sh" && bad "A5 agent-call still refuses on tripwire" || ok
grep -q 'TRIPWIRE_PAUSED' "$DIR/bin/lib/rb/plan.sh" && bad "A5 plan.sh still has TRIPWIRE_PAUSED" || ok

echo "build-tripwire-alert-only.bh-6705: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

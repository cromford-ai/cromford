#!/bin/bash
# tests/poll-commands-factory-stop.bh-3687-test.sh — BH-3712 (slice 5 of
# BH-3687): the poller's factory_stop handler, run from the block EXTRACTED
# VERBATIM from bin/poll-commands.sh (`# >>> factory_stop handler` /
# `# <<< factory_stop handler`; a missing marker fails loudly).
#
# The handler runs bin/factory-stop.sh and reports what it said. Here that CLI
# is a stub recording its argv and FACTORY_STOP_ACTOR:
#   K1 on + reason + actor -> the CLI ran with `on --reason hold` as that actor,
#      OK=true, RESULT is its last line;
#   K2 a blank or missing reason -> refused, OUTCOME=refused, CLI not run;
#   K3 a state that is not exactly on|off -> refused, CLI not run;
#   K4 CLI rc 1 / rc 3 -> OK=false, RESULT its last line, no OUTCOME (retryable);
#      rc 2 -> OUTCOME=refused;
#   K5 an actor outside the worker charset -> the CLI runs as `console`;
#   M1 (D1) a handler without the reason check must turn K2 red.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PC="${PC_UNDER_TEST:-$DIR/bin/poll-commands.sh}"
mkdir -p "$T/h/bin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

{ echo 'case "$TYPE" in'
  awk '/^    # >>> factory_stop handler/{f=1;next} /^    # <<< factory_stop handler/{exit} f{print}' "$PC"
  echo 'esac'
} > "$T/fs.body"
[ "$(wc -l < "$T/fs.body")" -gt 3 ] || { echo "FAIL: could not extract the factory_stop handler block — markers missing?"; exit 1; }

cat > "$T/h/bin/factory-stop.sh" <<'SH'
#!/bin/bash
printf 'actor=%s argv=%s\n' "${FACTORY_STOP_ACTOR:-}" "$*" >> "$STUB_LOG"
echo "some progress line"
echo ""
echo "factory-stop is ON (settings switch.factory-stop)"
echo ""
exit "${STUB_RC:-0}"
SH
chmod +x "$T/h/bin/factory-stop.sh"

STUB_LOG="$T/stub.log"
run() { # run <payload-json> [stub_rc] -> "OK=.. OUTCOME=.. RESULT=.."
  : > "$STUB_LOG"
  HARNESS="$T/h" STUB_LOG="$STUB_LOG" STUB_RC="${2:-0}" TYPE=factory_stop PROJECT=hub PAYLOAD="$1" \
    ID=7 OK=false RESULT="" OUTCOME="" \
    bash -c 'set -uo pipefail; . "$0"; echo "OK=$OK OUTCOME=$OUTCOME RESULT=$RESULT"' "$T/fs.body"
}
runs() { grep -c . "$STUB_LOG" 2>/dev/null || true; }

# K1
OUT=$(run '{"state":"on","reason":" hold ","actor":"operator@example.com"}')
eq "K1 ack" "$OUT" "OK=true OUTCOME= RESULT=factory-stop is ON (settings switch.factory-stop)"
eq "K1 the CLI saw its args and actor" "$(cat "$STUB_LOG")" "actor=operator@example.com argv=on --reason hold"
OUT=$(run '{"state":"off","reason":"done"}')
eq "K1 off, no actor -> console" "$(cat "$STUB_LOG")" "actor=console argv=off --reason done"

# K2
for p in '{"state":"on","reason":"  "}' '{"state":"on"}' '{"state":"off","reason":null}'; do
  OUT=$(run "$p")
  eq "K2 blank reason refused ($p)" "$OUT" "OK=false OUTCOME=refused RESULT=refused: reason required"
  eq "K2 CLI not run ($p)" "$(runs)" 0
done

# K3
for p in '{"state":"maybe","reason":"x"}' '{"state":"ON ","reason":"x"}' '{"reason":"x"}' '{"state":1,"reason":"x"}' 'not json'; do
  OUT=$(run "$p")
  eq "K3 invalid state refused ($p)" "$OUT" "OK=false OUTCOME=refused RESULT=refused: invalid state"
  eq "K3 CLI not run ($p)" "$(runs)" 0
done

# K4
OUT=$(run '{"state":"on","reason":"x"}' 1)
eq "K4 rc 1 is a retryable failure" "$OUT" "OK=false OUTCOME= RESULT=factory-stop is ON (settings switch.factory-stop)"
OUT=$(run '{"state":"on","reason":"x"}' 3)
eq "K4 rc 3 is a retryable failure" "${OUT%% RESULT=*}" "OK=false OUTCOME="
OUT=$(run '{"state":"on","reason":"x"}' 2)
eq "K4 rc 2 is a refusal" "${OUT%% RESULT=*}" "OK=false OUTCOME=refused"

# K5
for a in '"a b;rm"' '42' '""' '"x$(id)"'; do
  run "{\"state\":\"on\",\"reason\":\"x\",\"actor\":$a}" >/dev/null
  eq "K5 actor $a -> console" "$(cat "$STUB_LOG")" "actor=console argv=on --reason x"
done

# M1 (D1)
if [ -z "${PC_UNDER_TEST:-}" ]; then
  m="$T/mutant-pc.sh"
  sed '/# >>> factory_stop handler/,/# <<< factory_stop handler/s/elif \[ -z "\$FREASON" \]; then/elif false; then/' "$PC" > "$m"
  if cmp -s "$m" "$PC"; then bad "M1: the mutation did not apply"
  else
    out=$(PC_UNDER_TEST="$m" HARNESS_TEST_SANDBOX=1 bash "$0" 2>&1)
    grep -q "^FAIL: K2" <<<"$out" && ok || bad "M1: K2 stayed green without the reason check"
  fi
fi

echo "poll-commands-factory-stop: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

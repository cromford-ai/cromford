#!/bin/bash
# tests/say-is-a-function-not-tts-test.sh — a library's "use the caller's say()
# when it has one" check must accept only a shell function. `command -v say`
# also finds /usr/bin/say on macOS (text-to-speech), so a test run on a Mac
# spoke every log line out loud (172 lines on 2026-10-18).
#
#   S1  no file under bin/ asks `command -v say`, `type say`, `which say` or
#       `hash say`.
#   B1  bin/lib/handoff-watch.sh bhw__say with a `say` BINARY on PATH and no
#       say() function: the binary is not run, the line goes to the log.
#   B2  the same with a say() function defined: the function gets the line.
#   B3  bin/lib/pr-owner/shipped.sh _po_sh_say with only the binary: the
#       binary is not run, the line goes to stderr.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/say-is-a-function-not-tts-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }

# --- S1: the static scan ---------------------------------------------------
hits=$(grep -rnE '(command -v|type( -[a-zA-Z]+)?|which|hash) say([^a-zA-Z_-]|$)' "$DIR/bin" 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
[ -z "$hits" ] && ok || bad "S1: a say lookup that also finds the TTS binary: $hits"

# --- a fake text-to-speech binary that records each call -------------------
mkdir -p "$T/fakebin"
cat > "$T/fakebin/say" <<EOF
#!/bin/bash
echo "\$*" >> "$T/spoken"
EOF
chmod +x "$T/fakebin/say"
: > "$T/spoken"

# --- B1: no say() function, binary on PATH --------------------------------
mkdir -p "$T/h1"
( PATH="$T/fakebin:$PATH"; HARNESS="$T/h1"; unset -f say 2>/dev/null
  . "$DIR/bin/lib/handoff-watch.sh" && bhw__say "B1-line" ) >/dev/null 2>&1
[ ! -s "$T/spoken" ] && ok || bad "B1: the say binary ran: $(cat "$T/spoken")"
grep -q 'B1-line' "$T/h1/logs/blocked-resolver.log" 2>/dev/null && ok || bad "B1: the line is not in the log"

# --- B2: a say() function is defined ---------------------------------------
: > "$T/spoken"
out=$( PATH="$T/fakebin:$PATH"; HARNESS="$T/h2"
  say() { echo "fn:$*"; }
  . "$DIR/bin/lib/handoff-watch.sh" && bhw__say "B2-line" 2>/dev/null )
[ "$out" = "fn:B2-line" ] && ok || bad "B2: the say() function did not get the line (got '$out')"
[ ! -s "$T/spoken" ] && ok || bad "B2: the say binary ran"

# --- B3: pr-owner/shipped.sh helper with only the binary -------------------
: > "$T/spoken"
err=$( PATH="$T/fakebin:$PATH"; unset -f say 2>/dev/null
  eval "$(grep -E '^_po_sh_say\(\)' "$DIR/bin/lib/pr-owner/shipped.sh")"
  _po_sh_say "B3-line" 2>&1 >/dev/null )
[ ! -s "$T/spoken" ] && ok || bad "B3: the say binary ran: $(cat "$T/spoken")"
[ "$err" = "B3-line" ] && ok || bad "B3: the line is not on stderr (got '$err')"

echo "say-is-a-function-not-tts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

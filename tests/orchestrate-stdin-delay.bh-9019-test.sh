#!/bin/bash
# tests/orchestrate-stdin-delay.bh-9019-test.sh — a fresh orchestrator turn
# whose prompt takes more than 3 s to compose still reaches claude (BH-9019).
#
# WHY. Claude Code 2.1.317 waits 3 s for stdin when -p has no prompt argument,
# then prints "Warning: no stdin data received in 3s" and exits 1. run_turn's
# fresh path piped compose_v2_prompt straight into claude, and on the hub the
# compose took 34.9 s, so both model rungs exited 1 and the turn fell to
# survival. The fake claude below imitates that 3 s rule with 0 network calls,
# and this suite drives the REAL run_turn lifted out of bin/orchestrate.sh.
#
# determinism: ok-file this suite reads no clock and rolls no dice; the only
# timing is the fixture's own sleep 4 against the fake's read -t 3.
# Run from anywhere: tests/orchestrate-stdin-delay.bh-9019-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC=${ORC_SRC:-$DIR/bin/orchestrate.sh}
mkdir -p "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The fake CLI: argv to disk, then the 2.1.317 stdin rule.
cat > "$T/fakebin/claude" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$T_SENTINEL_DIR/argv.txt"
if ! IFS= read -r -N 1 -t 3 first; then
  echo "Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command, redirect stdin explicitly: < /dev/null to skip, or wait longer." >&2
  echo "Error: Input must be provided either through stdin or as a prompt argument when using --print" >&2
  exit 1
fi
printf 'GOT:%s' "$first"; cat
exit 0
FAKE
chmod +x "$T/fakebin/claude"

# S5: lift guard. A renamed function must fail here, not pass vacuously.
awk '/^run_turn\(\) \{/,/^}/' "$SRC" > "$T/orc-runturn.sh"
if [ -s "$T/orc-runturn.sh" ] && grep -q 'compose_v2_prompt' "$T/orc-runturn.sh"; then ok
else bad "S5: could not lift run_turn() (with its compose_v2_prompt call) from $SRC — the rest proves nothing"; fi

cat > "$T/orc-drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
orc_fresh() { return 0; }
budget_check() { :; }
note() { :; }
IRON_LAW_ARM=()
compose_v2_prompt() { sleep "${COMPOSE_DELAY:-0}"; printf 'BRIEFING-bh9019-fixture line1\nline2-end'; }
. "$T_SENTINEL_DIR/orc-runturn.sh"
if [ "${OLD_SHAPE:-0}" = 1 ]; then
  OUT=$(compose_v2_prompt | "$ORC_CLAUDE" -p 2>&1); RC=$?
else
  run_turn claude-x
fi
printf '%s' "$OUT" > "$T_SENTINEL_DIR/out.txt"
exit "$RC"
DRIVE
chmod +x "$T/orc-drive.sh"

drive() { # drive <COMPOSE_DELAY> [OLD_SHAPE]; sets OUT/RC
  rm -f "$T/argv.txt" "$T/out.txt"
  ( cd "$T" && env -i PATH="$T/fakebin:/usr/bin:/bin" T_SENTINEL_DIR="$T" HARNESS="$T" \
      ORC_CLAUDE="$T/fakebin/claude" ORC_BUDGET=1 TEXT=hi ORC_TOKEN="" \
      COMPOSE_DELAY="$1" OLD_SHAPE="${2:-0}" bash "$T/orc-drive.sh" >/dev/null 2>&1 )
  RC=$?
  OUT=$(cat "$T/out.txt" 2>/dev/null)
}

# S1: the bug. A 4 s compose against a 3 s stdin timer.
drive 4
[ "$RC" -eq 0 ] && ok || bad "S1: a 4 s compose made the fresh turn exit $RC (want 0): $OUT"
grep -qF 'GOT:BRIEFING-bh9019-fixture line1' <<<"$OUT" && ok || bad "S1: the first prompt line never reached claude: $OUT"
grep -qF 'line2-end' <<<"$OUT" && ok || bad "S1: the last prompt line never reached claude: $OUT"
if grep -qF 'no stdin data received' <<<"$OUT"; then bad "S1: the 3 s stdin warning is in the turn output: $OUT"; else ok; fi

# S4: argv unchanged — no prompt argument, the session id and model still there.
A="$T/argv.txt"
grep -qFx -- '-p' "$A" 2>/dev/null && ok || bad "S4: -p missing from claude's argv"
grep -qFx -- '--session-id' "$A" 2>/dev/null && ok || bad "S4: --session-id missing from claude's argv"
[ "$(grep -A1 -Fx -- '--model' "$A" 2>/dev/null | tail -1)" = "claude-x" ] && ok || bad "S4: --model is not followed by claude-x"
if grep -qFx -e 'BRIEFING-bh9019-fixture line1' -e 'line2-end' "$A" 2>/dev/null; then bad "S4: the prompt went out as argv"; else ok; fi

# S2: control. The old pipe shape with the same fake must fail like the CLI.
drive 4 1
[ "$RC" -eq 1 ] && ok || bad "S2: the old pipe shape exited $RC (want 1), so the fake does not imitate the 3 s rule"
grep -qF 'no stdin data received' <<<"$OUT" && ok || bad "S2: the old pipe shape printed no 3 s warning: $OUT"

# S3: a fast compose still delivers the full prompt.
drive 0
[ "$RC" -eq 0 ] && ok || bad "S3: a 0 s compose made the fresh turn exit $RC: $OUT"
grep -qF 'GOT:BRIEFING-bh9019-fixture line1' <<<"$OUT" && grep -qF 'line2-end' <<<"$OUT" \
  && ok || bad "S3: a 0 s compose did not deliver the full prompt: $OUT"

# S6: vendor budget. The fake claude resolves first on the driver's PATH, so a
# real claude at /usr/bin/claude (the hub and every pool box have one) is never
# called. The suite must stay green on those boxes: it asserts the resolution,
# not the absence of the binary.
[ "$(PATH="$T/fakebin:/usr/bin:/bin" command -v claude)" = "$T/fakebin/claude" ] \
  && ok || bad "S6: a claude other than the fake resolves first on the driver PATH"

echo "orchestrate-stdin-delay: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

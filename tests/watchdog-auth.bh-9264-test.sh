#!/bin/bash
# tests/watchdog-auth.bh-9264-test.sh — runs the watchdog worker's node test
# worker/watchdog/test/auth.bh-9264.test.js from the shell loop (CI's JS job only
# runs worker/jobs). It drives the real fetch export over the auth rules in
# worker/watchdog/src/auth.js: header auth, the phase 1 query-auth log line, the
# fallback-auth line and the refusal of WATCHDOG_SECRET == HARNESS_SECRET.
# Run from anywhere: tests/watchdog-auth.bh-9264-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
[ -f "$DIR/worker/watchdog/src/auth.js" ] || { echo "watchdog-auth.bh-9264-test: FAIL (worker/watchdog/src/auth.js missing)"; exit 1; }

# T3: Workers Logs keep the console lines, never the invocation records (they
# store the request URL, which holds ?s=<secret> until phase 2; lr-9278).
OBS=$(node -e '
  const t = require("fs").readFileSync(process.argv[1], "utf8")
    .replace(/"(?:[^"\\]|\\.)*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (m) => (m[0] === "\"" ? m : ""));
  const o = JSON.parse(t.replace(/,(\s*[}\]])/g, "$1")).observability || {};
  process.stdout.write(String(o.enabled === true) + " " + String(!!o.logs && o.logs.invocation_logs === false));
' "$DIR/worker/watchdog/wrangler.jsonc" 2>&1)
[ "$OBS" = "true true" ] || { echo "watchdog-auth.bh-9264-test: FAIL (wrangler.jsonc observability must be enabled with logs.invocation_logs false, got: $OBS)"; exit 1; }

NODE_TEST="worker/watchdog/test/auth.bh-9264.test.js"
[ -f "$DIR/$NODE_TEST" ] || { echo "watchdog-auth.bh-9264-test: FAIL ($NODE_TEST missing)"; exit 1; }
( cd "$DIR/worker/watchdog" && node --test --test-reporter=tap "$DIR/$NODE_TEST" ) > "$T/out.txt" 2>&1
RC=$?
PASSN=$(sed -n 's/^# pass \([0-9]*\)$/\1/p' "$T/out.txt" | tail -1)
if [ "$RC" -ne 0 ] || grep -q '^not ok' "$T/out.txt"; then
  cat "$T/out.txt"
  echo "watchdog-auth.bh-9264-test: FAIL (node rc=$RC)"; exit 1
fi
if [ "${PASSN:-0}" -eq 0 ]; then
  cat "$T/out.txt"
  echo "watchdog-auth.bh-9264-test: FAIL (the reporter shows 0 passing tests)"; exit 1
fi
echo "watchdog-auth.bh-9264-test: $PASSN pass, 0 fail"

#!/bin/bash
# tests/signals-console.bh-9839-test.sh — the console project Signals page
# (BH-9839, slice C1 of BH-9800): the page, the sheet, the client, the pure
# half, the coord write rows and the Fleet SIGNALS column.
#
# WHY A SHELL SUITE AS WELL. The screen is proved by node --test in
# console-ui/tests/signals-config.bh-9839.test.js (reached through the
# console-ui job). This file is the part the impact lane and the orphan
# ratchet can SEE: it names every new source by path, drives the pure half
# for real, and runs the node suite when the console dependencies are installed.
#
#   1. every new file exists.
#   2. lib/signal-keys.js, DRIVEN: trim, prefix check, pill states.
#   3. the stylesheet uses tokens only and main.js imports it once.
#   4. the node suite, run for real when console-ui/node_modules is installed.
#      Every fetch in it is a stub: 0 vendor calls.
# Run from anywhere: tests/signals-console.bh-9839-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PURE="$REPO/console-ui/src/lib/signal-keys.js"
CLIENT="$REPO/console-ui/src/lib/signal-keys-api.js"
PAGE="$REPO/console-ui/src/screens/settings/project/Signals.js"
SHEET="$REPO/console-ui/src/ui/SignalKeySheet.js"
CSS="$REPO/console-ui/src/signals.css"
ROWS="$REPO/console-ui/functions/_lib/coord-writes.d/9839-signal-keys.js"
SUITE="$REPO/console-ui/tests/signals-config.bh-9839.test.js"
DRIVE="$REPO/console-ui/tests/drive/signals.bh-9839-drive.mjs"
MAIN="$REPO/console-ui/src/main.js"

for f in "$PURE" "$CLIENT" "$PAGE" "$SHEET" "$CSS" "$ROWS" "$SUITE" "$DRIVE" "$MAIN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "signals-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 2: the pure half, driven -------------------------------------------------
OUT=$(node --input-type=module -e "
import { trimPaste, fieldError, pillState } from '$PURE';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const P = ['ph', 'x_'].join('');
const key = { name: 'key', label: 'Personal API key', placeholder: 'phx_…', re: '^[A-Za-z0-9_=+/.-]+\$', secret: 1, prefixes: [P] };
eq('trim',         trimPaste('  ' + P + 'fixture1\r\n'), P + 'fixture1');
eq('good',         fieldError(key, P + 'fixture1 '), null);
eq('bad-prefix',   fieldError(key, 'Bearer ' + P + 'fixture1'), 'Personal API key must start with ' + P);
eq('required',     fieldError(key, ' \n'), 'Personal API key is required');
const kinds = [{ kind: 'sentry', label: 'Sentry' }, { kind: 'posthog', label: 'PostHog' }];
const rows = [{ project: 'a', kind: 'sentry', last_test_result: 'ok' }, { project: 'a', kind: 'posthog', last_test_result: 'http_401' }, { project: 'b', kind: 'sentry', last_test_result: null }];
eq('pills-a',      pillState(kinds, rows, 'a').map((p) => p.state), ['set', 'failing']);
eq('pills-b',      pillState(kinds, rows, 'b').map((p) => p.state), ['set', 'missing']);
eq('pills-none',   pillState(kinds, rows, 'c').map((p) => p.state), ['missing', 'missing']);
" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok || bad "the pure-half driver exited $rc: $OUT"
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    *) bad "pure half: $line" ;;
  esac
done <<<"$OUT"

# --- 3: stylesheet ------------------------------------------------------------
if grep -qE '#[0-9a-fA-F]{3,8}\b' "$CSS"; then bad "signals.css holds a hex colour"; else ok; fi
n=$(grep -c "^import './signals.css';$" "$MAIN")
[ "$n" = 1 ] && ok || bad "main.js imports signals.css $n times"

# --- 4: the node suite ----------------------------------------------------------
if [ -d "$REPO/console-ui/node_modules/preact" ]; then
  LOG=$(mktemp)
  if (cd "$REPO/console-ui" && node --test tests/signals-config.bh-9839.test.js >"$LOG" 2>&1); then ok
  else bad "node --test console-ui/tests/signals-config.bh-9839.test.js failed:"; grep -E '^not ok' "$LOG"; fi
  rm -f "$LOG"
else
  echo "signals-console: node suite SKIPPED — console-ui/node_modules is not installed (CI's console-ui job runs it)"
fi

echo "signals-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

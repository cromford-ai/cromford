#!/bin/bash
# tests/unblock-console.bh-7728-test.sh — the console TACKLER screen on
# /unblock (BH-7728, UNB-6).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/unblock.bh-7728.test.js (reached through the console-ui job).
# What this file adds is the part the impact lane and the orphan ratchet can
# SEE: it names the two new sources by path, drives the pure half for real,
# and runs the node suite (the cost-breaker-console.bh-2331 pattern).
#
#   1. lib/unblock-api.js, DRIVEN against a stubbed fetch: the two GET paths,
#      the 503 "schema not applied" marked notLive, a 500 not marked, a 403 an
#      AuthError.
#   2. screens/Unblock.js, DRIVEN: subjectHref, percent and olderCursor.
#   3. the screen uses the shared SortableTable, /unblock is routed in app.js,
#      and no native dialog is called.
#   4. the node suite console-ui/tests/unblock.bh-7728.test.js, run for real
#      when the console-ui dependencies are installed.
# Run from anywhere: tests/unblock-console.bh-7728-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/unblock-api.js"
SCREEN="$DIR/console-ui/src/screens/Unblock.js"
APP="$DIR/console-ui/src/app.js"

for f in "$LIB" "$SCREEN" "$APP"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "unblock-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
globalThis.window = { location: { pathname: '/', search: '' }, addEventListener() {}, dispatchEvent() {} };
const calls = [];
let answer = [200, { ok: 1 }];
globalThis.fetch = async (url) => {
  calls.push(String(url));
  const [status, body] = answer;
  return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
};
const { unblockMetrics, unblockDecisions, isNotLive, SCHEMA_NOT_APPLIED } = await import('$LIB');
const { AuthError } = await import('$DIR/console-ui/src/api.js');
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const caught = async (fn) => { try { await fn(); return null; } catch (e) { return e; } };

await unblockMetrics('cromford', 7);
eq('metrics-path', calls.pop(), '/api/coord/unblock/metrics?project=cromford&days=7');
await unblockDecisions('cromford');
eq('decisions-path', calls.pop(), '/api/coord/unblock/metrics/decisions?project=cromford');
await unblockDecisions('project-3', 4410);
eq('decisions-before', calls.pop(), '/api/coord/unblock/metrics/decisions?project=project-3&before_id=4410');

answer = [503, { error: SCHEMA_NOT_APPLIED, detail: 'fixture' }];
const e503 = await caught(() => unblockMetrics('cromford', 7));
eq('503-notlive', [e503 && e503.status, e503 && e503.message, isNotLive(e503)], [503, 'unblock_decisions schema not applied', true]);
answer = [503, { error: 'overloaded' }];
eq('503-other', isNotLive(await caught(() => unblockDecisions('cromford'))), false);
answer = [500, { error: 'fixture boom' }];
const e500 = await caught(() => unblockDecisions('cromford'));
eq('500', [e500 && e500.status, e500 && e500.message, isNotLive(e500)], [500, 'fixture boom', false]);
answer = [403, { error: 'unauthorized' }];
eq('403-auth', (await caught(() => unblockMetrics('cromford', 7))) instanceof AuthError, true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's pure half, driven ---------------------------------------
if [ -d "$DIR/console-ui/node_modules/preact" ]; then
  OUT=$(node --input-type=module -e "
globalThis.window = { location: { pathname: '/', search: '' }, addEventListener() {}, dispatchEvent() {} };
const { subjectHref, percent, olderCursor } = await import('$SCREEN');
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('href-pr',   subjectHref({ project: 'cromford', subject_kind: 'pr', subject: 'example-org/cromford#7617' }), '/pr/cromford/7617');
eq('href-box',  subjectHref({ project: 'cromford', subject_kind: 'box', subject: 'box:box-fixture-1' }), '/machines?box=box-fixture-1');
eq('href-lane', subjectHref({ project: 'cromford', subject_kind: 'lane', subject: 'lane:merge-conductor' }), null);
eq('href-bad-pr', subjectHref({ project: 'cromford', subject_kind: 'pr', subject: 'no-number' }), null);
eq('pct',       percent(0.0952), '9.5');
eq('pct-null',  percent(null), null);
eq('older-next', olderCursor({ limit: 50, next_before_id: 4410, decisions: [{ id: 4460 }] }), 4410);
eq('older-none', olderCursor({ limit: 50, next_before_id: null, decisions: [{ id: 4460 }] }), null);
eq('older-last', olderCursor({ limit: 2, decisions: [{ id: 9 }, { id: 7 }] }), 7);
eq('older-short', olderCursor({ limit: 50, decisions: [{ id: 9 }] }), null);
" 2>&1)
  while IFS= read -r line; do
    case "$line" in
      ok\ *) ok ;;
      no\ *) bad "screen: ${line#no }" ;;
      *) [ -n "$line" ] && bad "screen: unexpected output: $line" ;;
    esac
  done <<< "$OUT"
else
  echo "unblock-console: screen drive SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
fi

# --- 3: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Unblock.js must use the shared SortableTable"
grep -q "\['/unblock', UnblockScreen\]" "$APP" && ok || bad "app.js must route /unblock to UnblockScreen"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the TACKLER screen"
else
  ok
fi

# --- 4: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "unblock-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/unblock.bh-7728.test.js 2>&1); then ok
  else bad "console-ui/tests/unblock.bh-7728.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "unblock-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/staff-chat-console.bh-6823-test.sh — the staff chat in the console
# (BH-6823): the CHAT pane on /staff/<agent> (the BH-6822 seam) and the STAFF
# tabs in /chat, plus the coord proxy row that lets a browser send a note.
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/staff-chat.bh-6823.test.js (reached through the console-ui
# job). This file is the part the impact lane and the orphan ratchet can SEE:
# it names the new sources by path, drives the pure half for real, and holds
# the pane to the rules a reviewer would otherwise check by eye.
#
#   1. lib/staff-chat.js, DRIVEN: the send body (trimmed; blank, over 4000 and
#      archie are null), the thread order (each note with its reply), the note
#      state copy ("answered" only off a reply row, "agent stopped" off held or
#      a live stop) and the tick link.
#   2. the coord write fragment is POST staff/chat with agent and text only;
#      take and settle are not browser rows.
#   3. the pane: no native dialog, mounted from Staff.js and Chat.js.
#   4. the node suite, run for real when the console-ui deps are installed.
# Run from anywhere: tests/staff-chat-console.bh-6823-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/staff-chat.js"
PANE="$DIR/console-ui/src/screens/staff/agent-chat.js"
FRAG="$DIR/console-ui/functions/_lib/coord-writes.d/6823-staff-chat.js"
CHATLIB="$DIR/console-ui/src/lib/chat.js"
CHAT="$DIR/console-ui/src/screens/Chat.js"
STAFF="$DIR/console-ui/src/screens/Staff.js"
for f in "$LIB" "$PANE" "$FRAG" "$CHATLIB" "$CHAT" "$STAFF"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "staff-chat-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { chatBody, threadRows, noteState, tickHref, STAFF_CHAT_TEXT_MAX } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const s = (n, o) => { const r = noteState(n, o); return r.tick ? r.text + ' ' + r.tick : r.text; };

eq('max',          STAFF_CHAT_TEXT_MAX, 4000);
eq('body',         chatBody(' Quartermaster ', '  hi  '), { agent: 'quartermaster', text: 'hi' });
eq('body-blank',   chatBody('quartermaster', '   '), null);
eq('body-long',    chatBody('quartermaster', 'x'.repeat(4001)), null);
eq('body-archie',  chatBody('archie', 'hi'), null);
eq('rows-bad',     threadRows(undefined), null);
const rows = threadRows([
  { id: 4, role: 'agent', reply_to: 3, tick_key: 'k', tick_id: 9, text: 'r' },
  { id: 3, role: 'operator', state: 'read', tick_key: 'k', text: 'q' },
  { id: 1, role: 'operator', state: 'pending', text: 'p' } ]);
eq('rows-order',   rows.map((r) => [r.note && r.note.id, r.reply && r.reply.id]), [[1, null], [3, 4]]);
eq('st-pending',   s({ state: 'pending' }), 'waiting for the next tick');
eq('st-stopped',   s({ state: 'pending' }, { stopped: true }), 'agent stopped: kept, read when it resumes');
eq('st-held',      s({ state: 'held' }), 'agent stopped: kept, read when it resumes');
eq('st-answered',  s({ state: 'read', tick_key: 'k' }, { reply: { tick_key: 'k' } }), 'answered in tick k');
eq('st-noreply',   s({ state: 'read', tick_key: 'k' }).startsWith('answered'), false);
eq('st-failed',    s({ state: 'failed', attempts: 2 }), 'not answered after 2 tries');
eq('href',         tickHref({ tick_id: 9 }), '/staff/tick/9');
eq('href-none',    tickHref({ tick_id: null }), null);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the coord write row -------------------------------------------------
FOUT=$(node --input-type=module -e "
const rows = (await import('$FRAG')).default;
console.log(rows.map((r) => r.method + ' ' + r.path + ' ' + r.body.join(',')).join(';'));
" 2>&1)
[ "$FOUT" = "POST staff/chat agent,text" ] && ok || bad "the coord write fragment: '$FOUT'"

# --- 3: the pane's shape ----------------------------------------------------
CODE=$(grep -hvE '^[[:space:]]*//' "$PANE" "$LIB" "$CHAT")
if [[ "$CODE" =~ (window\.|globalThis\.|[^.a-zA-Z_])(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the staff chat pane or /chat"
else
  ok
fi
grep -q "<\${AgentChat} agent=" "$STAFF" && ok || bad "Staff.js must mount AgentChat on the agent page"
grep -q "<\${AgentChat} key=" "$CHAT" && ok || bad "Chat.js must render AgentChat on a STAFF tab"
grep -q "buildTargets(projects, staffNames)" "$CHAT" && ok || bad "Chat.js must pass the staff names to buildTargets"

# --- 4: the node suite, driven ----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "staff-chat-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/staff-chat.bh-6823.test.js 2>&1); then ok
  else bad "console-ui/tests/staff-chat.bh-6823.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "staff-chat-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

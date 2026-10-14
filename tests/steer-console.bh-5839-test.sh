#!/bin/bash
# tests/steer-console.bh-5839-test.sh — the console half of BH-5839: the ticket
# page's "Step in" composer, its note echo and the coord proxy's POST steer row.
#
# WHY A SHELL SUITE AS WELL. The composer is proved by node --test in
# console-ui/tests/steer-composer.bh-5839.test.js and the proxy row by
# console-ui/tests/coord-steer-allowlist.bh-5839.test.js (both reached through
# the console-ui job). This file is the part the impact lane and the orphan
# ratchet can SEE: it names the new source by path, drives its pure half for
# real, and runs the two node suites when the console-ui dependencies are
# installed (the cost-breaker-console.bh-2331 pattern).
#
#   1. lib/steer.js, DRIVEN: a "now" note needs a running build, the caps
#      (500 for a hold, 4000 for the rest), the six echo states, and sendSteer:
#      a hold sends nothing until the dialog answers yes, a refusal is an
#      error and never a send.
#   2. the composer and the ticket page use lib/steer.js and the in-app
#      useConfirm, and call no native dialog.
#   3. the two node suites, run for real when the dependencies are installed.
# Run from anywhere: tests/steer-console.bh-5839-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/steer.js"
PANEL="$DIR/console-ui/src/ui/AgentSession.js"
SCREEN="$DIR/console-ui/src/screens/Ticket.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"

for f in "$LIB" "$PANEL" "$SCREEN" "$PROXY"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "steer-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { canSendNow, steerBody, steerState, sendSteer, STEER_TEXT_MAX } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

const RUN = { id: 'build-p-BH-1-1', kind: 'build', status: 'running' };
const DONE = { ...RUN, status: 'done' };
const base = { project: 'p', ticket: 'BH-1', text: ' hi ' };
eq('now-running',   canSendNow(RUN), true);
eq('now-done',      canSendNow(DONE), false);
eq('now-triage',    canSendNow({ ...RUN, kind: 'triage' }), false);
eq('now-null',      canSendNow(null), false);
eq('body-now',      steerBody({ ...base, mode: 'now', job: RUN }), { project: 'p', ticket: 'BH-1', mode: 'now', text: 'hi', job_id: RUN.id });
eq('body-now-done', steerBody({ ...base, mode: 'now', job: DONE }), null);
eq('body-ticket',   steerBody({ ...base, mode: 'ticket', job: RUN }), { project: 'p', ticket: 'BH-1', mode: 'ticket', text: 'hi' });
eq('body-hold',     steerBody({ ...base, mode: 'hold', job: RUN }).job_id, RUN.id);
eq('body-hold-500', steerBody({ ...base, mode: 'hold', job: RUN, text: 'x'.repeat(501) }), null);
eq('body-cap',      [STEER_TEXT_MAX, steerBody({ ...base, mode: 'ticket', job: null, text: 'x'.repeat(4001) })], [4000, null]);
eq('body-blank',    steerBody({ ...base, mode: 'ticket', job: null, text: '  ' }), null);
eq('body-mode',     steerBody({ ...base, mode: 'shout', job: RUN }), null);

const n = (o) => ({ id: 1, job_id: RUN.id, mode: 'now', status: 'pending', detail: null, build_read_at: null, ...o });
eq('state-waiting', steerState(n({}), RUN), 'waiting');
eq('state-read',    steerState(n({ status: 'read', build_read_at: '2026-10-12T09:07:00Z' }), RUN), 'read by the build at 09:07Z');
eq('state-posted',  steerState(n({ mode: 'ticket', status: 'delivered' }), RUN), 'posted');
eq('state-held',    steerState(n({ mode: 'hold', status: 'delivered' }), RUN), 'held');
eq('state-failed',  steerState(n({ mode: 'ticket', status: 'failed', detail: 'no App token' }), RUN), 'not delivered: no App token');
eq('state-ended',   steerState(n({}), DONE), 'not read: the build ended before its next step');

const run = async (mode, answer, reply) => {
  const sent = []; const asked = [];
  const r = await sendSteer({ ...base, mode, job: RUN,
    ask: async (o) => { asked.push(o.title); return answer; },
    apiObj: { steer: async (b) => { sent.push(b.mode); if (reply instanceof Error) throw reply; return reply; } } });
  return { r, sent, asked };
};
const t = await run('ticket', true, { note: { id: 2 } });
eq('send-ticket',   [t.sent, t.asked, t.r.ok], [['ticket'], [], true]);
const hc = await run('hold', false, { note: { id: 3 } });
eq('send-hold-cancel', [hc.sent, hc.asked, hc.r.ok], [[], ['HOLD TICKET'], false]);
const hy = await run('hold', true, { note: { id: 4 } });
eq('send-hold-yes', [hy.sent, hy.r.ok], [['hold'], true]);
const er = await run('ticket', true, new Error('text required'));
eq('send-refused',  [er.r.ok, er.r.error], [false, 'text required']);
const nb = await run('ticket', true, {});
eq('send-no-note',  nb.r.ok, false);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the composer's shape ------------------------------------------------
grep -q "from '../lib/steer.js'" "$PANEL" && ok || bad "AgentSession.js must build its body with lib/steer.js"
grep -q "useConfirm" "$PANEL" && ok || bad "AgentSession.js must confirm a hold through the in-app useConfirm modal"
grep -q "api.steerNotes" "$SCREEN" && ok || bad "Ticket.js must load the ticket's steer notes"
grep -q "path: 'steer'" "$DIR/console-ui/functions/_lib/coord-writes.d/5839-steer.js" && ok || bad "the coord write fragment 5839-steer.js must carry the POST steer row"
CODE=$(grep -hvE '^[[:space:]]*//' "$PANEL" "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window|globalThis)\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the Step in composer"
else
  ok
fi

# --- 3: the node suites, driven ---------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "steer-console: node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for s in tests/steer-composer.bh-5839.test.js tests/coord-steer-allowlist.bh-5839.test.js; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$s" 2>&1); then ok
    else bad "console-ui/$s failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
    fi
  done
fi

echo "steer-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

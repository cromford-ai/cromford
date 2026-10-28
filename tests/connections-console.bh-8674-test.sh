#!/bin/bash
# tests/connections-console.bh-8674-test.sh — the console's tracker
# connections screen (/connections, BH-8674, slice C1 of BH-7924).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/connections.bh-8674.test.js (reached through the console-ui
# job). What this file adds is the part the impact lane and the orphan ratchet
# can SEE: it names the four new sources by path, drives the pure half for
# real, and holds the screen to the rules a reviewer would otherwise check by
# eye (the cost-breaker-console.bh-2331 pattern).
#
#   1. lib/connections.js and connection-probe-command.js, DRIVEN: the token
#      refusal names the env var and never echoes the value, the near misses
#      pass, the rows and the credential summary, "probe queued" only on a
#      command id or ok, and the probe command admits connection-probe.sh with
#      the project as its one arg and nothing else.
#   2. Connections.js sorts through the shared SortableTable, edits in the
#      in-app Modal, never calls a native dialog; the coord write row lists the
#      PUT fields; the route, the settings row and the Project link exist.
#   3. the node suite console-ui/tests/connections.bh-8674.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/connections-console.bh-8674-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/connections.js"
SCREEN="$DIR/console-ui/src/screens/Connections.js"
PROBE="$DIR/console-ui/functions/_lib/connection-probe-command.js"
WRITES="$DIR/console-ui/functions/_lib/coord-writes.d/7924-connections.js"
APP="$DIR/console-ui/src/app.js"
MENU="$DIR/console-ui/src/lib/settings-menu.js"
SHELL_JS="$DIR/console-ui/src/screens/settings/Shell.js"
PROJECT_JS="$DIR/console-ui/src/screens/Project.js"

for f in "$LIB" "$SCREEN" "$PROBE" "$WRITES"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "connections-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the pure half, driven ------------------------------------------------
OUT=$(node --input-type=module -e "
import { checkConnectionForm, connectionRows, credentialSummary, probeNote, probeCommand, PROBE_QUEUED }
  from '$LIB';
import { connectionProbeCommand } from '$PROBE';
import writes from '$WRITES';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

const base = { project: 'pa', adapter: 'linear', team: 'CRO', label: 'ai-build', reason: 'r' };
const tok = checkConnectionForm({ ...base, label: 'lin_api_fixture9' });
eq('token-refused',  [tok.ok, tok.env_var], [false, 'LINEAR_API_KEY']);
eq('token-message',  tok.message, 'API keys are not stored here. Set LINEAR_API_KEY in env/pa.env on the box that runs pa.');
eq('token-no-echo',  JSON.stringify(tok).includes('lin_api_fixture9'), false);
eq('jira-env',       checkConnectionForm({ project: 'pj', adapter: 'jira', write_projects: 'ATATTfixture', reason: 'r' }).env_var, 'JIRA_API_TOKEN');
eq('key-refused',    checkConnectionForm({ ...base, api_key: 'x' }).ok, false);
eq('sk-label',       checkConnectionForm({ ...base, label: 'SK-1' }).ok, false);
for (const [k, v] of [['team', 'SK'], ['label', 'hotfix'], ['webhook_route', 'example-org/cromford-sandbox-linear']]) {
  eq('near-miss-' + k, checkConnectionForm({ ...base, [k]: v }).ok, true);
}
eq('jira-near-miss', checkConnectionForm({ project: 'pj', adapter: 'jira', write_projects: 'SKY', status_map: 'review=In Review;done=Done', reason: 'r' }).ok, true);
eq('no-reason',      checkConnectionForm({ ...base, reason: ' ' }).ok, false);

const rows = connectionRows({ connections: [
  { project: 'pa', adapter: 'linear', status: { ok: false, error: 'HTTP 401', checkedAt: '2026-10-27T10:00:00Z',
    credentialVars: { LINEAR_API_KEY: 'missing' } } },
  { project: 'pb', adapter: 'github-issues', status: { ok: true, credentialVars: {} } },
  { project: 'pc', adapter: 'board', status: null } ] });
eq('rows',           rows.map((r) => [r.project, r.ok, r.error]), [['pa', false, 'HTTP 401'], ['pb', true, null], ['pc', null, null]]);
eq('cred-summary',   rows.map(credentialSummary), ['missing LINEAR_API_KEY', 'none needed', null]);

eq('probe-queued',   probeNote('pa', { command_id: 3 }).text, 'pa: ' + PROBE_QUEUED);
eq('probe-ok',       probeNote('pa', { ok: true }).ok, true);
eq('probe-unproved', probeNote('pa', {}).ok, false);
eq('probe-refused',  probeNote('pa', null, new Error('unknown action')).text, 'pa: probe refused — unknown action');

const cmd = connectionProbeCommand({ ...probeCommand('pa'), actor: 'console' });
eq('cmd-payload',    cmd.payload, { script: 'connection-probe.sh', args: ['pa'], actor: 'console' });
eq('cmd-other',      connectionProbeCommand({ type: 'run_script', project: 'pa', script: 'security-audit-launch.sh', args: ['pa'] }), { error: 'unknown action' });
eq('cmd-args',       connectionProbeCommand({ type: 'run_script', project: 'pa', script: 'connection-probe.sh', args: ['--box'] }), { error: 'unknown action' });

eq('write-row',      writes.map((r) => [r.method, r.path]), [['PUT', 'connections']]);
eq('write-fields',   writes[0].body.includes('api_key') || writes[0].body.includes('actor'), false);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape and its entry points -------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Connections.js must use the shared SortableTable"
grep -q "from '../ui/Modal.js'" "$SCREEN" && ok || bad "Connections.js must edit in the in-app Modal"
NONCOMMENT=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$NONCOMMENT" =~ (^|[^A-Za-z0-9_])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the connections screen"
else
  ok
fi
grep -q "\['/connections', ConnectionsScreen\]" "$APP" && ok || bad "app.js must route /connections"
grep -q "{ id: 'connections', label: 'Tracker connections' }" "$MENU" && ok || bad "the settings menu must have the connections row"
grep -q "connections: ConnectionsScreen" "$SHELL_JS" && ok || bad "Shell.js must mount ConnectionsScreen"
grep -q '/connections?project=' "$PROJECT_JS" && ok || bad "Project.js must link to /connections?project=<p>"

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "connections-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/connections.bh-8674.test.js 2>&1); then ok
  else bad "console-ui/tests/connections.bh-8674.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "connections-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/fleet-machines-console.bh-7978-test.sh — the fleet Machines page in
# the console settings shell (BH-7978, BH-7939.4 slice C0).
#
# The screen is proved by node --test in
# console-ui/tests/onboard-fly-choices.bh-7939.test.js (the console-ui job).
# This file is the part the impact lane and the orphan ratchet can SEE: it
# names every new source by path, drives the pure helpers for real (they
# import nothing), and runs the node suite when the dependencies are installed.
#
#   1. lib/fly-settings.js, DRIVEN: only '1' sets a flag, the gate text and
#      link, the Fly org slug rule.
#   2. the wiring: the menu row has no tag, the shell mounts the page, and the
#      page calls no native dialog.
#   3. the node suite, run for real when console-ui/node_modules is installed.
#      Its case S1 asserts the page asks for one same-origin URL: 0 vendor calls.
# Run from anywhere: tests/fleet-machines-console.bh-7978-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

FLY="$DIR/console-ui/src/lib/fly-settings.js"
PAGE="$DIR/console-ui/src/screens/settings/fleet/Machines.js"
MENU="$DIR/console-ui/src/lib/settings-menu.js"
SHELL_JS="$DIR/console-ui/src/screens/settings/Shell.js"
NODE_TEST="$DIR/console-ui/tests/onboard-fly-choices.bh-7939.test.js"

for f in "$FLY" "$PAGE" "$MENU" "$SHELL_JS" "$NODE_TEST"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "fleet-machines-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the helpers, driven ----------------------------------------------------
OUT=$(node --input-type=module -e "
import { flySettingsFrom, flyGate, checkFlyOrg } from '$FLY';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const flag = (v) => flySettingsFrom([{ key: 'fly.token_present', value: v }]).tokenPresent;
eq('one',        flag('1'), true);
eq('one-spaced', flag(' 1 '), true);
eq('zero',       flag('0'), false);
eq('true-word',  flag('true'), false);
eq('eleven',     flag('11'), false);
eq('no-row',     flySettingsFrom({ settings: [] }).tokenPresent, false);
eq('gate-closed', flyGate({ tokenPresent: false }), { enabled: false, reason: 'Add your Fly API token first', href: '/settings/fleet/machines#fly-token' });
eq('gate-open',  flyGate({ tokenPresent: true }).enabled, true);
eq('org-ok',     checkFlyOrg(' my-org ').value, 'my-org');
eq('org-upper',  checkFlyOrg('My-Org').ok, false);
eq('org-dash',   checkFlyOrg('-org').ok, false);
eq('org-empty',  checkFlyOrg('').ok, false);
eq('org-64',     checkFlyOrg('a'.repeat(64)).ok, false);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "fly-settings: ${line#no }" ;;
    *) [ -n "$line" ] && bad "fly-settings: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the wiring -------------------------------------------------------------
grep -q "{ id: 'machines', label: 'Machines and Tailscale' }" "$MENU" && ok || bad "the machines menu row must have no tag"
grep -q "machines: FleetMachinesScreen" "$SHELL_JS" && ok || bad "Shell.js must mount FleetMachinesScreen for machines"
grep -q "from './fleet/Machines.js'" "$SHELL_JS" && ok || bad "Shell.js must import ./fleet/Machines.js"
CODE=$(grep -hvE '^[[:space:]]*//' "$PAGE" "$FLY")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog on the fleet Machines page"
else
  ok
fi

# --- 3: the node suite, driven -------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "fleet-machines-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/onboard-fly-choices.bh-7939.test.js 2>&1); then ok
  else bad "console-ui/tests/onboard-fly-choices.bh-7939.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "fleet-machines-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

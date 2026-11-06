#!/bin/bash
# tests/sidemenu-console.bh-9118-test.sh — the Mission Control side menu
# (BH-9118): every screen in a left menu by group, a collapse rail, Team links
# from the staff roster, and a phone drawer opened by the top bar's hamburger.
#
# The behaviour is proved by node --test in console-ui/tests/sidemenu.bh-9118.test.js.
# This file is the part the impact lane and the orphan ratchet can SEE: it
# names the new files by path, drives the pure half with node, and runs the
# node suite when the console-ui dependencies are installed.
#
#   1. the new sources, the suite, the drive and its shared locator exist, and
#      main.js imports sidemenu.css.
#   2. lib/sidemenu.js, DRIVEN: a saved-closed group stays open on its own
#      screen, a failed roster read is an error and not an empty roster, and a
#      bad stored value reads as the defaults.
#   3. the node suite, run for real when node_modules is present.
# Run from anywhere: tests/sidemenu-console.bh-9118-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/sidemenu.js"
MENU="$DIR/console-ui/src/ui/SideMenu.js"
CSS="$DIR/console-ui/src/sidemenu.css"
MAIN="$DIR/console-ui/src/main.js"
DRIVE="$DIR/console-ui/tests/drive/sidemenu-drive.mjs"
NAVLOC="$DIR/console-ui/tests/drive/nav.mjs"
SUITE="tests/sidemenu.bh-9118.test.js"

for f in "$LIB" "$MENU" "$CSS" "$MAIN" "$DRIVE" "$NAVLOC" "$DIR/console-ui/$SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
grep -q "^import './sidemenu.css';" "$MAIN" && ok || bad "main.js does not import sidemenu.css"

command -v node >/dev/null 2>&1 || { echo "sidemenu-console: SKIPPED — node is not installed on this box"; echo "sidemenu-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

# --- 2: the pure half ----------------------------------------------------------
OUT=$(node --input-type=module -e "
import { menuGroups, teamLinks, readMenuPrefs } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const NAV = [
  { to: '/a', label: 'A', group: 'g1', match: (p) => p === '/a' },
  { to: '/b', label: 'B', group: 'g2', match: (p) => p === '/b' }
];
const G = [{ id: 'g1', label: 'G1' }, { id: 'g2', label: 'G2' }, { id: 'g3', label: 'G3' }];
const open = (p, saved) => menuGroups(NAV, G, p, saved).map((g) => g.id + ':' + g.open).join(' ');
eq('saved-closed', open('/a', { g2: false }), 'g1:true g2:false');
eq('active-stays-open', open('/b', { g2: false }), 'g1:true g2:true');
eq('roster-failed', teamLinks(null, '/'), { links: [], error: true });
eq('roster-empty', teamLinks({ agents: [] }, '/'), { links: [], error: false });
const store = { getItem: (k) => (k === 'ui.sidemenu.groups' ? '{bad' : '1') };
eq('bad-json-defaults', readMenuPrefs(store), { collapsed: false, groups: {} });
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    *) bad "lib: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the node suite -----------------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ] || [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "sidemenu-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test "$SUITE" 2>&1); then ok
  else bad "node suite $SUITE"; echo "$NOUT" | grep -E '^not ok|# (pass|fail)' | head -20; fi
fi

echo "sidemenu-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

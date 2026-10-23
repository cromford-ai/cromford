#!/bin/bash
# tests/settings-shell-console.bh-7938-test.sh — the console settings side
# menu (BH-7938, slice C0): the registry, the shell, the legacy redirects.
#
# WHY A SHELL SUITE AS WELL. The screen is proved by node --test in
# console-ui/tests/settings-shell.bh-7938.test.js (reached through the
# console-ui job). This file is the part the impact lane and the orphan ratchet
# can SEE: it names every new source by path, drives the pure registry for
# real (it imports nothing, so it needs no console dependencies), and runs the
# node suite when the dependencies are installed.
#
#   1. lib/settings-menu.js, DRIVEN: the legacy paths redirect with the query
#      and hash kept, the near misses do not, and a tagged row has no href.
#   2. Shell.js mounts Lanes and Appearance, app.js routes the shell and
#      resolves the redirect, the stylesheet is imported and uses tokens only,
#      and no native dialog is called.
#   3. the node suite, run for real when console-ui/node_modules is installed.
#      Its case B1 asserts every URL the shell and its pages ask for is a
#      same-origin /api/ URL: 0 vendor calls.
# Run from anywhere: tests/settings-shell-console.bh-7938-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MENU="$DIR/console-ui/src/lib/settings-menu.js"
SHELL_JS="$DIR/console-ui/src/screens/settings/Shell.js"
CSS="$DIR/console-ui/src/settings-shell.css"
DRIVE="$DIR/console-ui/tests/drive/settings-shell.bh-7938-drive.mjs"
APP="$DIR/console-ui/src/app.js"
MAIN="$DIR/console-ui/src/main.js"

for f in "$MENU" "$SHELL_JS" "$CSS" "$DRIVE" "$APP" "$MAIN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "settings-shell-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the registry, driven -------------------------------------------------
OUT=$(node --input-type=module -e "
import { SETTINGS_MENU, redirectFor, menuFor, itemHref } from '$MENU';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('settings',        redirectFor('/settings'), '/settings/fleet/lanes');
eq('settings-slash',  redirectFor('/settings/'), '/settings/fleet/lanes');
eq('settings-query',  redirectFor('/settings', '?project=project-3'), '/settings/fleet/lanes?project=project-3');
eq('appearance-hash', redirectFor('/settings/appearance', '', '#custom'), '/settings/fleet/appearance#custom');
eq('fleet',           redirectFor('/settings/fleet'), '/settings/fleet/lanes');
eq('lane',            redirectFor('/settings/merge-conductor'), null);
eq('new-path',        redirectFor('/settings/fleet/lanes'), null);
eq('prefix',          redirectFor('/settingsx'), null);
eq('substring',       redirectFor('/settings/appearancex'), null);
const items = menuFor(SETTINGS_MENU, { scope: 'fleet', page: 'lanes' }).flatMap((g) => g.items);
eq('prompts-href',    items.find((i) => i.id === 'prompts').href, '/settings/fleet/prompts');
eq('ai-vendors-tag',  items.find((i) => i.id === 'ai-vendors').tag, 'wave 4');
eq('ai-vendors-no-href', items.find((i) => i.id === 'ai-vendors').href, null);
eq('lanes-href',      items.find((i) => i.id === 'lanes').href, '/settings/fleet/lanes');
eq('project-href',    itemHref('project', 'general', 'a b'), '/settings/p/a%20b/general');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "menu: ${line#no }" ;;
    *) [ -n "$line" ] && bad "menu: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the wiring -------------------------------------------------------------
grep -q "lanes: SettingsScreen, appearance: AppearanceScreen" "$SHELL_JS" && ok || bad "Shell.js must mount Lanes and Appearance unchanged"
grep -q "\['/settings/fleet/:page', SettingsFleetScreen\]" "$APP" && ok || bad "app.js must route /settings/fleet/:page"
grep -q "\['/settings/p/:project/:page', SettingsProjectScreen\]" "$APP" && ok || bad "app.js must route /settings/p/:project/:page"
grep -q "redirectFor(path, search, hash)" "$APP" && ok || bad "app.js resolveRoute must ask redirectFor"
grep -q "^import './settings-shell.css';" "$MAIN" && ok || bad "main.js must import settings-shell.css"
if grep -Eiq '#[0-9a-f]{3,8}\b|rgba?\(' "$CSS"; then bad "settings-shell.css holds a colour literal (tokens only)"; else ok; fi
CODE=$(grep -hvE '^[[:space:]]*//' "$SHELL_JS" "$MENU")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the settings shell"
else
  ok
fi

# --- 3: the node suite, driven -------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "settings-shell-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/settings-shell.bh-7938.test.js 2>&1); then ok
  else bad "console-ui/tests/settings-shell.bh-7938.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "settings-shell-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

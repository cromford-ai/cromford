#!/bin/bash
# tests/prompts-console.bh-7973-test.sh — the console prompts list and editor
# (BH-7973, BH-7940.5).
#
# The screens are proved by node --test in console-ui/tests/prompts.bh-7973.test.js
# (reached through the console-ui job). This file names every new source by
# path, so the impact lane and the orphan ratchet can see them, and:
#   1. lib/prompts.js, DRIVEN: the line diff, the CRLF case, the marker lint
#      and the repo paths (the lib imports only api.js and settings-menu.js,
#      so it needs no console dependencies);
#   2. the wiring: the shell mounts PromptsScreen, the editor imports the
#      marker catalog and the history seam, and no native dialog is called;
#   3. the node suite, run for real when console-ui/node_modules is installed.
#      Every fetch in it is a stub that refuses a URL outside /api/prompts:
#      0 vendor calls.
# Run from anywhere: tests/prompts-console.bh-7973-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/prompts.js"
SCREEN="$DIR/console-ui/src/screens/Prompts.js"
EDITOR="$DIR/console-ui/src/ui/PromptEditor.js"
SHELL_JS="$DIR/console-ui/src/screens/settings/Shell.js"
MENU="$DIR/console-ui/src/lib/settings-menu.js"
SUITE="$DIR/console-ui/tests/prompts.bh-7973.test.js"

for f in "$LIB" "$SCREEN" "$EDITOR" "$SHELL_JS" "$MENU" "$SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "prompts-console-7973: FAIL — node is not installed on this box"; exit 1; }

# --- 1: the pure half, driven ------------------------------------------------
OUT=$(node --input-type=module -e "
import { lineDiff, missingMarkers, repoPath, listHref, PROMPT_KINDS } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const ops = (d) => d.map((x) => x.op + x.text);
eq('diff-add',        ops(lineDiff('a\nc', 'a\nb\nc')), [' a', '+b', ' c']);
eq('diff-replace',    ops(lineDiff('a\nb\nc', 'a\nX\nc')), [' a', '-b', '+X', ' c']);
eq('diff-crlf',       ops(lineDiff('a\r\nb', 'a\nb')), [' a', ' b']);
eq('diff-empty-old',  ops(lineDiff('', 'one')), ['+one']);
const cat = { review: ['VERDICT:'] };
eq('lint-lower',      missingMarkers('review', 'verdict: x', cat), ['VERDICT:']);
eq('lint-no-colon',   missingMarkers('review', 'VERDICT x', cat), ['VERDICT:']);
eq('lint-at-end',     missingMarkers('review', 'x\nVERDICT:', cat), []);
eq('lint-unknown',    missingMarkers('nope', '', cat), []);
eq('repo-rules',      repoPath('rules', 'p'), 'rules/CLAUDE.md');
eq('repo-watcher',    repoPath('watcher', 'p'), 'prompts/p.md');
eq('repo-stage',      repoPath('qa', 'p'), 'prompts/stages/qa.md');
eq('list-href',       listHref('project', 'zz-p'), '/settings/p/zz-p/prompts');
eq('kinds',           PROMPT_KINDS.length, 7);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the wiring -------------------------------------------------------------
grep -q "prompts: PromptsScreen" "$SHELL_JS" && ok || bad "Shell.js must mount PromptsScreen for the prompts row"
grep -q "catalog/prompt-markers.json' with { type: 'json' }" "$EDITOR" && ok || bad "PromptEditor.js must import the marker catalog"
grep -q "from './PromptHistoryActions.js'" "$EDITOR" && ok || bad "PromptEditor.js must import the history seam"
if grep -q "wave 6b" "$MENU"; then bad "settings-menu.js still tags a row 'wave 6b'"; else ok; fi
CODE=$(grep -hvE '^[[:space:]]*//' "$LIB" "$SCREEN" "$EDITOR")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)|(^|[^A-Za-z0-9_.])(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the prompts screens"
else
  ok
fi

# --- 3: the node suite, driven -------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "prompts-console-7973: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/prompts.bh-7973.test.js 2>&1); then ok
  else bad "console-ui/tests/prompts.bh-7973.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "prompts-console-7973: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

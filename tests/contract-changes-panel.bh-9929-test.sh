#!/bin/bash
# tests/contract-changes-panel.bh-9929-test.sh — the CONTRACT CHANGES section
# on /p/<project> (BH-9929).
#
# WHY A SHELL SUITE AS WELL. The panel's behaviour is proved by node --test in
# console-ui/tests/contract-changes-panel.bh-9929.test.js (reached through the
# console-ui job). This file is the part the impact lane and the orphan ratchet
# can SEE: it names the new screen by path, drives its pure half (issueHref) for
# real, and holds the screen to the rules a reviewer would otherwise check by
# eye (the cost-breaker-console.bh-2331 pattern).
#
#   1. issueHref, DRIVEN: a github PR URL plus a positive parent ticket gives
#      the parent issue URL; anything else gives null (no dead link).
#   2. ContractChangesPanel.js sorts through the shared SortableTable, reads
#      through api.contractChanges, is mounted on Project.js, and never calls a
#      native dialog.
#   3. the node suite, run for real when the console-ui dependencies exist.
# Run from anywhere: tests/contract-changes-panel.bh-9929-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/ContractChangesPanel.js"
PROJECT="$DIR/console-ui/src/screens/Project.js"
API="$DIR/console-ui/src/api.js"
NODE_SUITE="$DIR/console-ui/tests/contract-changes-panel.bh-9929.test.js"

for f in "$SCREEN" "$PROJECT" "$API" "$NODE_SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the screen rules, by text ---------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "ContractChangesPanel.js must use the shared SortableTable"
grep -q "api.contractChanges(project)" "$SCREEN" && ok || bad "ContractChangesPanel.js must read through api.contractChanges"
grep -q "contractChanges:.*/api/coord/contract-changes?project=" "$API" && ok || bad "api.js must carry contractChanges on /api/coord/contract-changes"
grep -q "import ContractChangesPanel from './ContractChangesPanel.js'" "$PROJECT" && ok || bad "Project.js must import ContractChangesPanel"
grep -q '<${ContractChangesPanel} project=${project}/>' "$PROJECT" && ok || bad "Project.js must mount ContractChangesPanel"
if grep -nE '(^|[^.\w])(window\.)?(confirm|alert|prompt)\(' "$SCREEN"; then
  bad "ContractChangesPanel.js must not call a native browser dialog"
else ok; fi
grep -q 'overflow-x:auto' "$SCREEN" && ok || bad "the table must scroll inside its own overflow-x:auto container"

command -v node >/dev/null 2>&1 || {
  echo "contract-changes-panel: $PASS passed, $FAIL failed (node SKIPPED — node is not installed on this box)"
  [ "$FAIL" -eq 0 ]; exit; }

# --- 1: issueHref, driven -----------------------------------------------------
# The screen imports preact through router.js, so the pure function is taken out
# of the source text and evaluated alone; no console dependency is needed.
OUT=$(node --input-type=module -e "
import { readFileSync } from 'node:fs';
const src = readFileSync('$SCREEN', 'utf8');
const re = src.match(/^const REPO_FROM_PR = .*;\$/m);
const fn = src.match(/^export function issueHref\(row\) \{[\s\S]*?^\}/m);
if (!re || !fn) { console.log('no source'); process.exit(0); }
const issueHref = new Function(re[0] + '\n' + fn[0].replace(/^export /, '') + '\nreturn issueHref;')();
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('pr+ticket',  issueHref({ pr_url: 'https://github.com/example-org/project-6-os/pull/412', parent_ticket: 40 }),
                 'https://github.com/example-org/project-6-os/issues/40');
eq('pr-files',   issueHref({ pr_url: 'https://github.com/a/b/pull/7/files', parent_ticket: '9' }), 'https://github.com/a/b/issues/9');
eq('no-pr',      issueHref({ pr_url: null, parent_ticket: 40 }), null);
eq('not-gh',     issueHref({ pr_url: 'https://evil.example/a/b/pull/1', parent_ticket: 40 }), null);
eq('js-url',     issueHref({ pr_url: 'javascript:alert(1)', parent_ticket: 40 }), null);
eq('zero',       issueHref({ pr_url: 'https://github.com/a/b/pull/1', parent_ticket: 0 }), null);
eq('non-number', issueHref({ pr_url: 'https://github.com/a/b/pull/1', parent_ticket: 'x' }), null);
" 2>&1)
[ -n "$OUT" ] || bad "issueHref: node printed nothing"
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    *) bad "issueHref: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the node suite, driven ------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "contract-changes-panel: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/contract-changes-panel.bh-9929.test.js 2>&1); then ok
  else bad "console-ui/tests/contract-changes-panel.bh-9929.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "contract-changes-panel: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

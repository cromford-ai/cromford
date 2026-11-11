#!/bin/bash
# tests/alert-family-console.bh-9114-test.sh — the BY FAMILY strip on the
# Mission Control Alerts screen (BH-9114).
#
# The behaviour is proved by node --test in
# console-ui/tests/alert-family.bh-9114.test.js. This suite is the part the
# impact lane and the orphan ratchet can see (the cost-breaker-console.bh-2331
# pattern):
#   1. lib/alert-family.js, DRIVEN: the classifier, the counts order, the
#      family filter and the pill href.
#   2. Alerts.js mounts the strip on the SAME open rows, reads ?openfamily=,
#      and the OPEN ALERTS table renders the filtered rows.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/alert-family-console.bh-9114-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/alert-family.js"
SCREEN="$DIR/console-ui/src/screens/Alerts.js"
for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "alert-family-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
# The lib imports ../router.js, which needs preact/htm, so it is driven only
# when the console-ui dependencies are installed.
if [ -d "$DIR/console-ui/node_modules/preact" ]; then
  OUT=$(cd "$DIR/console-ui" && node --input-type=module -e "
import { alertFamily, familyCounts, filterByFamily, openFamilyHref } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('ph',        alertFamily('alert:ph-staleremote-project-3-12'), 'ph-staleremote');
eq('hb-pid',    alertFamily('orclane:hb-pr-owner-sweep-1710927-3'), 'hb-pr-owner-sweep');
eq('warnbatch', alertFamily('warnbatch:hub:20261105120000:1'), 'warnbatch');
eq('mq',        alertFamily('mq-headbound:project-3:12'), 'mq-headbound');
eq('auto',      alertFamily('alert:auto-abc123'), 'auto');
eq('empty',     alertFamily(''), '(no key)');
eq('PH-case',   alertFamily('PH-x'), 'PH-x');
eq('counts',    familyCounts([{ akey: 'b:1' }, { akey: 'a:1' }, { akey: 'b:2' }]), [{ family: 'b', n: 2 }, { family: 'a', n: 1 }]);
eq('filter',    filterByFamily([{ akey: 'b:1' }, { akey: 'a:1' }], 'a').length, 1);
eq('href',      openFamilyHref('warnbatch', 'project-3'), '/alerts?project=project-3&openfamily=warnbatch');
" 2>&1)
  while IFS= read -r line; do
    case "$line" in
      ok\ *) ok ;;
      no\ *) bad "lib: ${line#no }" ;;
      *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
    esac
  done <<< "$OUT"
else
  echo "alert-family-console: lib drive SKIPPED — console-ui dependencies are not installed"
fi

# --- 2: the screen's wiring ---------------------------------------------------
grep -q "from '../lib/alert-family.js'" "$SCREEN" && ok || bad "Alerts.js must import the family lib"
grep -q "useSearchParam('openfamily')" "$SCREEN" && ok || bad "Alerts.js must read ?openfamily="
grep -q 'filterByFamily(open, openFamily)' "$SCREEN" && ok || bad "Alerts.js must filter the open rows by the chosen family"
grep -q 'rows=${openShown}' "$SCREEN" && ok || bad "the OPEN ALERTS table must render the filtered rows"
grep -q '<${AlertFamilyStrip} rows=${open}' "$SCREEN" && ok || bad "the strip must count the same open rows OPEN NOW counts"

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "alert-family-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/alert-family.bh-9114.test.js 2>&1); then ok
  else bad "console-ui/tests/alert-family.bh-9114.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "alert-family-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

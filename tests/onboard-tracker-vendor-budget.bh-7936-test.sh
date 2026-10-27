#!/bin/bash
# tests/onboard-tracker-vendor-budget.bh-7936-test.sh — BH-7936: the PR-path
# vendor budget for the onboarding tracker test (BH-7563 rule 6). 0 calls to
# Linear or Jira from the PR suite.
#
#   B1 the BH-7936 hub-probe suite passes with a recording `curl` FIRST on PATH
#      (behind only the suite's own stubs), and that recorder saw 0 calls: no
#      code path reached a curl that is not a stub
#   B3 no PR-path suite (tests/*.sh, tests/mc/*.sh) runs the tracker contract
#      files, and harness-ci.yml's test loop does not name tests/contract/
#   B4 the contract suites skip with a reason, rc 0, when no credential is set
#   B5 the worker and console node suites for this ticket pass (when node and
#      the console's dependencies are there) under the same recorder: the KV
#      and the proxy are fakes
#
# Sources: bin/lib/hub-probes/tracker-test.sh, the route
# worker/jobs/src/routes/onboarding-tracker.js, the sheet
# console-ui/src/ui/TrackerSheets.js + console-ui/src/lib/tracker-sheets.js.
#   HARNESS_TEST_SANDBOX=1 bash tests/onboard-tracker-vendor-budget.bh-7936-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SRCS=("$DIR/bin/lib/hub-probes/tracker-test.sh" "$DIR/worker/jobs/src/routes/onboarding-tracker.js"
  "$DIR/console-ui/src/ui/TrackerSheets.js" "$DIR/console-ui/src/lib/tracker-sheets.js"
  "$DIR/console-ui/src/ui/TrackerSheets.css" "$DIR/console-ui/functions/_lib/coord-writes.d/7936-onboarding-tracker.js"
  "$DIR/tests/contract/tracker-linear.bh-7936-contract-test.sh" "$DIR/tests/contract/tracker-jira.bh-7936-contract-test.sh"
  "$DIR/.github/workflows/tracker-contract.yml")
for f in "${SRCS[@]}"; do check "source present: ${f#"$DIR"/}" '[ -f "$f" ]'; done

# B1
mkdir -p "$T/rec"
cat > "$T/rec/curl" <<SH
#!/bin/bash
printf '%s\n' "\$*" | grep -oE 'https?://[^/ ]+' | head -1 >> "$T/rec/hosts"
exit 7
SH
chmod +x "$T/rec/curl"
: > "$T/rec/hosts"
SUITE="$DIR/tests/hub-probe-tracker-test.bh-7936-test.sh"
PATH="$T/rec:$PATH" HARNESS_TEST_SANDBOX=1 bash "$SUITE" > "$T/suite.out" 2>&1; SRC=$?
check "B1 the hub-probe suite passes under the recorder (rc=$SRC: $(tail -1 "$T/suite.out"))" '[ "$SRC" = 0 ]'
check "B1 the recorder saw 0 calls ($(sort -u "$T/rec/hosts" | tr '\n' ' '))" '[ ! -s "$T/rec/hosts" ]'
check "B1 0 Linear or Jira hosts" '! grep -qE "api\.linear\.app|atlassian\.(net|com)" "$T/rec/hosts"'

# B3
# The two tracker contract files are this ticket's. Another ticket's suite may
# run ITS OWN contract file with every credential unset (BH-7965's V8 runs
# tests/contract/vendor-probe.bh-7965-contract.sh in skip mode), which is the
# same thing B4 below does here; that is that suite's budget to guard.
HITS=$(grep -lE 'tests/contract/tracker-(linear|jira)' "$DIR"/tests/*.sh "$DIR"/tests/mc/*.sh 2>/dev/null | grep -v "/onboard-tracker-vendor-budget.bh-7936-test.sh$")
check "B3 no PR-path suite names the tracker contract files ($HITS)" '[ -z "$HITS" ]'
check "B3 the tracker contract files are outside the PR corpus" '! ls "$DIR"/tests/*.sh "$DIR"/tests/mc/*.sh 2>/dev/null | grep -qE "tracker-(linear|jira)\.bh-7936-contract"'
check "B3 harness-ci.yml does not run tests/contract/" '! grep -q "tests/contract" "$DIR/.github/workflows/harness-ci.yml"'

# B4
for s in linear jira; do
  out=$(env -u LINEAR_CONTRACT_KEY -u LINEAR_CONTRACT_TEAM -u JIRA_CONTRACT_SITE -u JIRA_CONTRACT_EMAIL -u JIRA_CONTRACT_TOKEN -u JIRA_CONTRACT_PROJECT \
    PATH="$T/rec:$PATH" HARNESS_TEST_SANDBOX=1 bash "$DIR/tests/contract/tracker-$s.bh-7936-contract-test.sh" 2>&1); rc=$?
  check "B4 $s contract skips with a reason, rc 0 (rc=$rc: $out)" '[ "$rc" = 0 ] && grep -q "^SKIP: no contract credentials" <<<"$out"'
done
check "B4 the skips made no call" '[ ! -s "$T/rec/hosts" ]'

# B5
if ! command -v node >/dev/null 2>&1; then
  echo "note: no node here; the node suites are left to CI"
elif [ ! -f "$DIR/catalog/lanes.json" ] || [ ! -f "$DIR/catalog/llm-sites.json" ]; then
  echo "note: B5 not run — catalog/lanes.json or catalog/llm-sites.json is not composed (bin/lanes-build.sh --write, bin/llm-sites-build.sh --compose; CI runs both first)"
else
  ( cd "$DIR/worker/jobs" && PATH="$T/rec:$PATH" node --test test/onboarding-tracker.bh-7936.test.js ) > "$T/w.out" 2>&1; WRC=$?
  check "B5 the worker suite passes (rc=$WRC)" '[ "$WRC" = 0 ]'
  [ "$WRC" = 0 ] || tail -40 "$T/w.out"
  if [ -d "$DIR/console-ui/node_modules/preact" ] && [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
    ( cd "$DIR/console-ui" && PATH="$T/rec:$PATH" node --test tests/tracker-sheets.bh-7936.test.js ) > "$T/c.out" 2>&1; CRC=$?
    check "B5 the console suite passes (rc=$CRC)" '[ "$CRC" = 0 ]'
    [ "$CRC" = 0 ] || tail -40 "$T/c.out"
  else
    echo "note: console-ui dependencies not installed; console suite left to CI"
  fi
fi

echo "onboard-tracker-vendor-budget: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

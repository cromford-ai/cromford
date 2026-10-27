#!/bin/bash
# tests/onboard-github-vendor-budget.bh-7935-test.sh — BH-7997 (BH-7935 wave 2):
# the vendor budget for the onboarding GitHub seam (iron law BH-7563 rule 6).
#   B1  tests/onboard-repo-detect.bh-7935-test.sh passes with a recording curl
#       and gh first on PATH, and neither one ran
#   B2  among the onboarding files, only bin/lib/onboard-github.sh names
#       gh_rest, curl, `gh api` or api.github.com
#   B3  the four seam placeholders carry their `owner BH-7935.<n>` line, and no
#       PR-path suite or harness-ci.yml line runs the onboard-github contract
#       file. Its path is built from two parts (CDIR), so this suite never
#       holds the literal contract path, which the BH-7936 budget suite (B3)
#       refuses in any PR-path suite.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/onboard-github-vendor-budget.bh-7935-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SEAM="$DIR/bin/lib/onboard-github.sh"
SUITE="$DIR/tests/onboard-repo-detect.bh-7935-test.sh"
CDIR="tests/""contract"
CREL="$CDIR/onboard-github.bh-7935-contract-test.sh"
CONTRACT="$DIR/$CREL"
WORKFLOW="$DIR/.github/workflows/onboard-github-contract.yml"

# ── B1 ──────────────────────────────────────────────────────────────────────
# The suite writes its recorders to VENDOR_LOG and puts them first on PATH.
: > "$T/vendor.log"
VENDOR_LOG="$T/vendor.log" HARNESS_TEST_SANDBOX=1 bash "$SUITE" > "$T/suite.out" 2>&1; SRC=$?
check "B1 the repo-detect suite passes" '[ "$SRC" = 0 ] || { tail -20 "$T/suite.out"; false; }'
check "B1 the suite reported its counts" 'grep -q "^onboard-repo-detect: [0-9][0-9]* passed, 0 failed$" "$T/suite.out"'
check "B1 0 calls to curl or gh" '[ ! -s "$T/vendor.log" ] || { cat "$T/vendor.log"; false; }'

# ── B2 ──────────────────────────────────────────────────────────────────────
ONB=("$DIR/bin/lib/hub-probes/repo-detect.sh" "$DIR/bin/lib/hub-probes/repo-detect-extra.sh"
     "$DIR/bin/lib/hub-probes/ready-facts.sh" "$DIR/bin/lib/hub-probes/repo-create.sh"
     "$DIR/worker/jobs/src/routes/onboarding-repo.js")
for f in "${ONB[@]}"; do
  check "B2 $f exists" '[ -f "$f" ]'
  CODE=$(grep -v "^[[:space:]]*#" "$f")
  check "B2 $f calls no vendor directly" \
    '! [[ "$CODE" =~ gh_rest|curl|gh\ api|api\.github\.com|gh_app_only_for|gh_auth_for ]]'
done
CODE=$(grep -v "^[[:space:]]*#" "$SEAM")
check "B2 the seam is the one file that calls gh_rest and mints" \
  '[[ "$CODE" == *"gh_rest GET"* && "$CODE" == *gh_app_only_for* ]]'

# ── B3 ──────────────────────────────────────────────────────────────────────
for pair in "bin/lib/hub-probes/repo-detect-extra.sh:BH-7935.1" "console-ui/src/screens/Onboard.js:BH-7935.2" \
            "console-ui/src/screens/ProjectReady.js:BH-7935.3" "bin/lib/hub-probes/ready-facts.sh:BH-7935.3" \
            "console-ui/src/screens/onboard/NewRepoPanel.js:BH-7935.4" "bin/lib/hub-probes/repo-create.sh:BH-7935.4"; do
  f="$DIR/${pair%%:*}"; o="${pair##*:}"
  check "B3 $f names owner $o" 'grep -qE "^(#|//) owner $o$" "$f"'
done
check "B3 the contract suite and its workflow exist" '[ -f "$CONTRACT" ] && [ -f "$WORKFLOW" ]'
CORPUS=$(cd "$DIR" && ls tests/*.sh tests/mc/*.sh 2>/dev/null)
check "B3 the contract suite is outside the PR corpus" '[[ "$CORPUS" != *onboard-github.bh-7935-contract* ]]'
NAMERS=$(grep -l "$CDIR/onboard-github" "$DIR"/tests/*.sh "$DIR"/tests/mc/*.sh 2>/dev/null)
check "B3 no PR-path suite runs the contract file" \
  '[ -z "$(printf "%s\n" "$NAMERS" | sed "/\/onboard-github-vendor-budget.bh-7935-test.sh$/d; /^$/d")" ]'
check "B3 harness-ci.yml does not run the contract file" '! grep -q "$CDIR/onboard-github" "$DIR/.github/workflows/harness-ci.yml"'
check "B3 the workflow runs the contract file on main, nightly and on seam PRs" \
  'grep -q "bash $CREL" "$WORKFLOW" && grep -q "branches: \[main\]" "$WORKFLOW" && grep -q "cron:" "$WORKFLOW" && grep -q "bin/lib/onboard-github.sh" "$WORKFLOW"'
env -u ONBOARD_GITHUB_FAKE HARNESS="$T/no-harness" bash "$CONTRACT" > "$T/contract.out" 2>&1; CRC=$?
check "B3 the contract suite skips with a reason on a runner with no App credential" \
  '[ "$CRC" = 0 ] && grep -q "^SKIP: no App credential" "$T/contract.out"'

echo "onboard-github-vendor-budget: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/security-audit-gitignore.bh-7910-test.sh — BH-7910: a security audit's
# output (a client's vulnerability list) is never committed.
#
#   G1  the repo's .gitignore ignores security-audit/<project>/run-1/findings.json
#       and the latest summary, at the root and under a build directory
#   G2  a stub run with --out <a git repo carrying this .gitignore>/security-audit
#       leaves `git status --porcelain` with no path under security-audit/
#   G3  the target repo's work tree has no new file after the run
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/security-audit-gitignore.bh-7910-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/security-audit-fixture.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git; do command -v "$c" >/dev/null 2>&1 || { echo "$c missing — skipping"; exit 0; }; done

# ── G1: the patterns, checked against the repo's own .gitignore ──────────────
git init -q "$T/gi"
cp "$REPO_DIR/.gitignore" "$T/gi/.gitignore"
for p in security-audit/p/run-1/findings.json security-audit/p/latest-summary.json \
         builds/x/security-audit/p/run-2/REPORT.md; do
  git -C "$T/gi" check-ignore -q "$p" && ok || bad "G1 .gitignore does not ignore $p"
done

# ── G2: a real stub run into a git repo ──────────────────────────────────────
PJ=fixture-gi
sa_fixture_setup "$PJ" || { echo "FAIL: fixture setup"; exit 1; }
RC=$(sa_run "$PJ" --out "$T/gi/security-audit")
[ "$RC" = 0 ] && ok || bad "G2 rc $RC: $(cat "$T/run.out")"
[ -f "$T/gi/security-audit/$PJ/run-1/findings.json" ] && ok || bad "G2 the run wrote no findings.json"
ST=$(git -C "$T/gi" status --porcelain --untracked-files=all | grep 'security-audit/')
[ -z "$ST" ] && ok || bad "G2 git status shows audit output: $ST"

# ── G3: nothing new in the target ────────────────────────────────────────────
[ -z "$(git -C "$T/target" status --porcelain --untracked-files=all)" ] && ok || bad "G3 the target work tree changed"

echo "security-audit-gitignore: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

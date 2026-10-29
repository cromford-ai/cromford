#!/bin/bash
# tests/contract/onboard-github.bh-7935-contract-test.sh — BH-7997 (BH-7935
# wave 2): the REAL-GitHub contract suite for bin/lib/onboard-github.sh, the
# onboarding GitHub seam (iron law BH-7563 rule 4). One worker.
#   C0  no App credential on this runner -> `SKIP: no App credential`, rc 0
#   C1  og_get repos/<HARNESS_REPO> is rc 0 and the body has default_branch
#   C2  og_get on a repo that does not exist is rc 44
#   C3  a malformed path is rc 2 and reads nothing
#   C4  hp_probe_repo_detect <HARNESS_REPO> prints visible:true with the facts
#   C5  og_install_url has the /apps/<slug>/installations/new shape
#   C6  og_get repos/<HARNESS_REPO>/actions/workflows: a numeric total_count
#   C7  og_get repos/<HARNESS_REPO>/contents: an array, a type on each entry
#   C8  og_clone <HARNESS_REPO> <empty temp dir>: files, and no remote left
# A vendor that cannot answer (rc 75) is a vendor failure, not a code failure
# (rule 7): `SKIP: vendor unverifiable`, a ::warning:: line and ONE
# bin/alert-line.sh --id onboard-github-contract line, rc 0.
# It reads the App credential of the harness it runs beside (HARNESS, default
# /root/harness). It writes only its temp files (removed on exit) and, on a
# vendor skip, the alert line. It is NOT in the PR corpus (tests/*.sh,
# tests/mc/*.sh): .github/workflows/onboard-github-contract.yml runs it on main,
# nightly, and on a PR that changes the seam or this file.
# Run: bash tests/contract/onboard-github.bh-7935-contract-test.sh  (exit 0 = pass or skip)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "onboard-github-contract: jq is required"; exit 1; }
unset ONBOARD_GITHUB_FAKE  # the contract reads the real vendor, never the fake
. "$DIR/bin/lib/gh-app-auth.sh" || exit 1
. "$DIR/bin/lib/onboard-github.sh" || exit 1
. "$DIR/bin/lib/hub-probes/repo-detect.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
vendor_skip() {
  echo "SKIP: vendor unverifiable ($1, HTTP ${OG_HTTP_STATUS:-000})"
  echo "::warning::onboard-github contract: GitHub did not answer ($1); a vendor failure, not a code failure"
  "$DIR/bin/alert-line.sh" --id onboard-github-contract \
    "onboard-github-contract: vendor failure at $1 (skipped, not a code failure)" >/dev/null 2>&1 || true
  exit 0
}

if ! gh_auth_armed; then echo "SKIP: no App credential (gh_auth_armed is false on this runner)"; exit 0; fi

if [[ "${HARNESS_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then REPO=$HARNESS_REPO
else REPO=$(unset HARNESS_REPO; . "$DIR/bin/lib/deployment.sh" && printf %s "$HARNESS_REPO"); fi
OUT=$(mktemp "${TMPDIR:-/tmp}/og-contract.XXXXXX") || exit 1
CLONE=$(mktemp -d "${TMPDIR:-/tmp}/og-contract-clone.XXXXXX") || { rm -f "$OUT"; exit 1; }
trap 'rm -f "$OUT"; rm -rf "$CLONE"' EXIT

# C1
rc=0; og_get "repos/$REPO" > "$OUT" 2>/dev/null || rc=$?
[ "$rc" = 75 ] && vendor_skip "C1 repos/$REPO"
if [ "$rc" = 0 ] && jq -e '.default_branch | type == "string"' "$OUT" >/dev/null 2>&1; then ok
else bad "C1 repos/$REPO rc=$rc (want 0 with default_branch)"; fi

# C2
rc=0; og_get "repos/${REPO%%/*}/onboard-contract-missing-bh-7935" > "$OUT" 2>/dev/null || rc=$?
[ "$rc" = 75 ] && vendor_skip "C2 missing repo"
if [ "$rc" = 44 ]; then ok; else bad "C2 a missing repo rc=$rc (want 44)"; fi

# C3
rc=0; og_get "repos/${REPO%%/*}/../x" > "$OUT" 2>/dev/null || rc=$?
if [ "$rc" = 2 ] && [ ! -s "$OUT" ]; then ok; else bad "C3 a malformed path rc=$rc (want 2, no body)"; fi

# C4
rc=0; line=$(hp_probe_repo_detect "$REPO" 2>/dev/null) || rc=$?
[ "$line" = unverifiable ] && vendor_skip "C4 hp_probe_repo_detect"
if [ "$rc" = 0 ] && jq -e '.visible == true and (.default_branch | type == "string") and (.has_issues | type == "boolean") and (.open_issues | type == "number")' <<< "$line" >/dev/null 2>&1; then ok
else bad "C4 hp_probe_repo_detect $REPO rc=$rc: ${line:0:200}"; fi

# C5
if [[ "$(og_install_url)" =~ ^https://github\.com/apps/[a-z0-9-]+/installations/new$ ]]; then ok
else bad "C5 og_install_url: $(og_install_url)"; fi

# C6
rc=0; og_get "repos/$REPO/actions/workflows" > "$OUT" 2>/dev/null || rc=$?
[ "$rc" = 75 ] && vendor_skip "C6 workflows"
if [ "$rc" = 0 ] && jq -e '.total_count | type == "number"' "$OUT" >/dev/null 2>&1; then ok
else bad "C6 repos/$REPO/actions/workflows rc=$rc (want 0 with a numeric total_count)"; fi

# C7
rc=0; og_get "repos/$REPO/contents" > "$OUT" 2>/dev/null || rc=$?
[ "$rc" = 75 ] && vendor_skip "C7 contents"
if [ "$rc" = 0 ] && jq -e 'type == "array" and length > 0 and all(.[]; (.type | type) == "string")' "$OUT" >/dev/null 2>&1; then ok
else bad "C7 repos/$REPO/contents rc=$rc (want 0 with an array of typed entries)"; fi

# C8
rc=0; og_clone "$REPO" "$CLONE" >/dev/null 2>&1 || rc=$?
[ "$rc" = 75 ] && vendor_skip "C8 clone"
if [ "$rc" = 0 ] && [ -n "$(ls -A "$CLONE")" ] && [ -z "$(git -C "$CLONE" remote 2>/dev/null)" ]; then ok
else bad "C8 og_clone $REPO rc=$rc (want 0, files, no remote)"; fi

echo "onboard-github-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

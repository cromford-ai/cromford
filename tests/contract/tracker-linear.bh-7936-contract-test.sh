#!/bin/bash
# tests/contract/tracker-linear.bh-7936-contract-test.sh — BH-7936: the
# real-vendor contract suite for the Linear seam (bin/lib/tracker/linear.sh).
# Five cases against the live Linear API, one worker, read-only plus one
# TRK_DRY=1 write that sends nothing:
#   L1 tracker_list answers rc 0 and a JSON array
#   L2 tracker_read of the first listed id has the normalized keys
#   L3 TRK_DRY=1 tracker_comment prints one DRYRUN line and sends nothing
#   L4 a bad key answers rc 1
#   L5 the team key resolves to one Linear team
#
# It is NOT in the PR suite: tests/*.sh and tests/mc/*.sh are the CI glob, and
# this file is under tests/contract/. .github/workflows/tracker-contract.yml
# runs it on main, nightly, and on a PR that changes the tracker seam files.
#
# CREDENTIALS. LINEAR_CONTRACT_KEY and LINEAR_CONTRACT_TEAM (repo secrets; the
# cromford-sandbox-linear sandbox). LINEAR_CONTRACT_LABEL is optional
# (default ai-build). No key: `SKIP: no contract credentials`, rc 0.
# A VENDOR FAILURE (rc 75: 429, 5xx, timeout, RATELIMITED) is not a code
# failure: `SKIP: vendor failure <case>`, one bin/alert-line.sh --id
# tracker-contract line, rc 0. A wrong shape is rc 1.
#   HARNESS_TEST_SANDBOX=1 bash tests/contract/tracker-linear.bh-7936-contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
if [ -z "${LINEAR_CONTRACT_KEY:-}" ] || [ -z "${LINEAR_CONTRACT_TEAM:-}" ]; then
  echo "SKIP: no contract credentials (LINEAR_CONTRACT_KEY, LINEAR_CONTRACT_TEAM)"
  exit 0
fi
# The scratch tree only after the credential check: a skip writes nothing.
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$DIR/bin/lib/tracker.sh" || exit 1
tracker_load linear || { echo "FAIL: tracker_load linear"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
vendor_skip() { # vendor_skip <case> — rule 7: a vendor error is a vendor failure
  echo "SKIP: vendor failure $1"
  mkdir -p "$T/h/logs"
  HARNESS="$T/h" "$DIR/bin/alert-line.sh" --id tracker-contract "tracker-contract: linear vendor failure at $1 (skipped, not a code failure)" >/dev/null 2>&1 || true
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::tracker-contract linear: vendor failure at $1"
  echo "tracker-linear contract: $PASS passed, $FAIL failed, stopped at $1 (vendor)"
  exit "$([ "$FAIL" = 0 ] && echo 0 || echo 1)"
}

export TRK_LINEAR_TOKEN="$LINEAR_CONTRACT_KEY" TRK_LINEAR_TOKEN_VAR=LINEAR_CONTRACT_KEY
export TRK_LINEAR_TEAM="$LINEAR_CONTRACT_TEAM" TRK_LINEAR_LABEL="${LINEAR_CONTRACT_LABEL:-ai-build}"
export TRK_ERR="$T/err"

# L1
rc=0; LIST=$(tracker_list) || rc=$?
[ "$rc" = 75 ] && vendor_skip L1
if [ "$rc" = 0 ] && jq -e 'type == "array"' <<<"$LIST" >/dev/null 2>&1; then ok "L1 list is a JSON array ($(jq length <<<"$LIST") open)"
else bad "L1 list rc=$rc"; fi
FIRST=$(jq -r '.[0].id // empty' <<<"$LIST" 2>/dev/null)

# L2 + L3 need one labelled open issue.
if [ -z "$FIRST" ]; then
  echo "SKIP: L2 L3 need one open issue with label $TRK_LINEAR_LABEL in team $TRK_LINEAR_TEAM"
else
  rc=0; ONE=$(tracker_read "$FIRST") || rc=$?
  [ "$rc" = 75 ] && vendor_skip L2
  if [ "$rc" = 0 ] && jq -e 'has("id") and has("key") and has("title") and has("body") and has("status") and (.labels|type=="array") and has("waitingOn") and has("triageVerdict") and has("url") and (.comments|type=="array")' <<<"$ONE" >/dev/null 2>&1; then
    ok "L2 read has the normalized keys"
  else bad "L2 read rc=$rc"; fi
  printf 'contract dry run, never sent\n' > "$T/body"
  rc=0; DRY=$(TRK_DRY=1 tracker_comment "$FIRST" "$T/body") || rc=$?
  [ "$rc" = 75 ] && vendor_skip L3
  if [ "$rc" = 0 ] && [ "$(grep -c '^DRYRUN ' <<<"$DRY")" = 1 ] && ! grep -q "$LINEAR_CONTRACT_KEY" <<<"$DRY"; then ok "L3 one DRYRUN line, key not shown"
  else bad "L3 dry comment rc=$rc out=$(head -c 200 <<<"$DRY")"; fi
fi

# L4
rc=0; TRK_LINEAR_TOKEN=lin-api-fixture-not-a-key tracker_list >/dev/null || rc=$?
[ "$rc" = 75 ] && vendor_skip L4
[ "$rc" = 1 ] && ok "L4 a bad key is rc 1" || bad "L4 a bad key rc=$rc"

# L5
rc=0; TEAM=$(_trk_linear_gql 'query TrkTeam($key: String!) { teams(filter: { key: { eq: $key } }) { nodes { id key } } }' '{key: $key}' --arg key "$TRK_LINEAR_TEAM") || rc=$?
[ "$rc" = 75 ] && vendor_skip L5
if [ "$rc" = 0 ] && [ "$(jq -r --arg k "$TRK_LINEAR_TEAM" '[.teams.nodes[] | select(.key == $k)] | length' <<<"$TEAM")" = 1 ]; then ok "L5 team $TRK_LINEAR_TEAM resolves"
else bad "L5 team rc=$rc"; fi

echo "tracker-linear contract: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

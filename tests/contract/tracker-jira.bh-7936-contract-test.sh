#!/bin/bash
# tests/contract/tracker-jira.bh-7936-contract-test.sh — BH-7936: the
# real-vendor contract suite for the Jira seam (bin/lib/tracker/jira.sh), with
# the context built from sheet fields (trk_jira_context_fields). Five cases
# against the live Jira Cloud gateway, one worker:
#   J1 tracker_list answers rc 0 and a JSON array
#   J2 tracker_read of the first listed key has the normalized keys
#   J3 TRK_DRY=1 tracker_comment prints one DRYRUN line and sends nothing
#   J4 a bad token answers rc 1
#   J5 trk_jira_cloud_id answers a UUID for the site
#
# It is NOT in the PR suite (tests/contract/ is outside the CI glob).
# .github/workflows/tracker-contract.yml runs it on main, nightly, and on a PR
# that changes the tracker seam files.
#
# CREDENTIALS. JIRA_CONTRACT_SITE (<x>.atlassian.net), JIRA_CONTRACT_EMAIL,
# JIRA_CONTRACT_TOKEN, JIRA_CONTRACT_PROJECT (repo secrets; the
# cromford-sandbox-jira sandbox). Any one missing: `SKIP: no contract
# credentials`, rc 0. A VENDOR FAILURE (rc 75) is `SKIP: vendor failure
# <case>`, one bin/alert-line.sh --id tracker-contract line, rc 0.
#   HARNESS_TEST_SANDBOX=1 bash tests/contract/tracker-jira.bh-7936-contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
if [ -z "${JIRA_CONTRACT_SITE:-}" ] || [ -z "${JIRA_CONTRACT_EMAIL:-}" ] || [ -z "${JIRA_CONTRACT_TOKEN:-}" ] || [ -z "${JIRA_CONTRACT_PROJECT:-}" ]; then
  echo "SKIP: no contract credentials (JIRA_CONTRACT_SITE, JIRA_CONTRACT_EMAIL, JIRA_CONTRACT_TOKEN, JIRA_CONTRACT_PROJECT)"
  exit 0
fi
# The scratch tree only after the credential check: a skip writes nothing.
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$DIR/bin/lib/tracker.sh" || exit 1
tracker_load jira || { echo "FAIL: tracker_load jira"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
vendor_skip() { # vendor_skip <case> — rule 7: a vendor error is a vendor failure
  echo "SKIP: vendor failure $1"
  mkdir -p "$T/h/logs"
  HARNESS="$T/h" "$DIR/bin/alert-line.sh" --id tracker-contract "tracker-contract: jira vendor failure at $1 (skipped, not a code failure)" >/dev/null 2>&1 || true
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::tracker-contract jira: vendor failure at $1"
  echo "tracker-jira contract: $PASS passed, $FAIL failed, stopped at $1 (vendor)"
  exit "$([ "$FAIL" = 0 ] && echo 0 || echo 1)"
}
SMAP='todo=To Do;in_progress=In Progress;review=In Review;closed=Done'
export TRK_ERR="$T/err"

# J5 first: every other case needs the gateway base it finds.
rc=0; CID=$(trk_jira_cloud_id "$JIRA_CONTRACT_SITE" 2>"$T/j5.err") || rc=$?
[ "$rc" = 75 ] && vendor_skip J5
[[ "$rc" = 0 && "$CID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && ok "J5 cloud id is a UUID" \
  || { bad "J5 cloud id rc=$rc"; echo "tracker-jira contract: $PASS passed, $FAIL failed"; exit 1; }

rc=0; trk_jira_context_fields "$JIRA_CONTRACT_SITE" "$JIRA_CONTRACT_EMAIL" "$JIRA_CONTRACT_TOKEN" "$JIRA_CONTRACT_PROJECT" "$SMAP" || rc=$?
[ "$rc" = 75 ] && vendor_skip J1
[ "$rc" = 0 ] || { bad "J1 context rc=$rc"; echo "tracker-jira contract: $PASS passed, $FAIL failed"; exit 1; }

# J1
rc=0; LIST=$(tracker_list) || rc=$?
[ "$rc" = 75 ] && vendor_skip J1
if [ "$rc" = 0 ] && jq -e 'type == "array"' <<<"$LIST" >/dev/null 2>&1; then ok "J1 list is a JSON array ($(jq length <<<"$LIST") open)"
else bad "J1 list rc=$rc"; fi
FIRST=$(jq -r '.[0].id // empty' <<<"$LIST" 2>/dev/null)

if [ -z "$FIRST" ]; then
  echo "SKIP: J2 J3 need one open issue with label ai-build in $JIRA_CONTRACT_PROJECT"
else
  rc=0; ONE=$(tracker_read "$FIRST") || rc=$?
  [ "$rc" = 75 ] && vendor_skip J2
  if [ "$rc" = 0 ] && jq -e 'has("id") and has("key") and has("title") and has("body") and has("status") and (.labels|type=="array") and has("waitingOn") and has("triageVerdict") and has("url") and (.comments|type=="array")' <<<"$ONE" >/dev/null 2>&1; then
    ok "J2 read has the normalized keys"
  else bad "J2 read rc=$rc"; fi
  printf 'contract dry run, never sent\n' > "$T/body"
  rc=0; DRY=$(TRK_DRY=1 tracker_comment "$FIRST" "$T/body") || rc=$?
  [ "$rc" = 75 ] && vendor_skip J3
  if [ "$rc" = 0 ] && [ "$(grep -c '^DRYRUN ' <<<"$DRY")" = 1 ] && ! grep -q "$JIRA_CONTRACT_TOKEN" <<<"$DRY"; then ok "J3 one DRYRUN line, token not shown"
  else bad "J3 dry comment rc=$rc"; fi
fi

# J4
rc=0; TRK_JIRA_TOKEN=tok-fixture-not-a-token tracker_list >/dev/null 2>&1 || rc=$?
[ "$rc" = 75 ] && vendor_skip J4
[ "$rc" = 1 ] && ok "J4 a bad token is rc 1" || bad "J4 a bad token rc=$rc"

echo "tracker-jira contract: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

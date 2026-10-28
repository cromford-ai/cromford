#!/bin/bash
# tests/contract/connection-probe.bh-7924-contract-test.sh — BH-7924: the
# real-vendor contract cases for the two connection-probe reads and for
# bin/connection-probe.sh itself, against the sandbox accounts. One worker,
# read-only:
#   K1 Jira: trk_jira_myself answers rc 0 on the contract credentials
#   K2 Linear: trk_linear_viewer answers rc 0 on the contract key
#   K3 a bad Linear key: trk_linear_viewer answers rc 1, and
#      bin/connection-probe.sh --dry-run prints ok:false, writes nothing, and
#      does not print the key
#
# It is NOT in the PR suite: tests/*.sh and tests/mc/*.sh are the CI glob, and
# this file is under tests/contract/.
#
# CREDENTIALS. K1: JIRA_CONTRACT_SITE, JIRA_CONTRACT_EMAIL, JIRA_CONTRACT_TOKEN,
# JIRA_CONTRACT_PROJECT. K2 and K3: LINEAR_CONTRACT_KEY (K3 sends a fixture
# key, but only where a Linear sandbox is configured). A case with no
# credentials is `SKIP: no contract credentials`, rc 0. A VENDOR FAILURE
# (rc 75: 429, 5xx, timeout, RATELIMITED) is `SKIP: vendor failure <case>`,
# one bin/alert-line.sh --id tracker-contract line, rc 0. A wrong answer is rc 1.
#   HARNESS_TEST_SANDBOX=1 bash tests/contract/connection-probe.bh-7924-contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
HAVE_JIRA=0; HAVE_LINEAR=0
[ -n "${JIRA_CONTRACT_SITE:-}" ] && [ -n "${JIRA_CONTRACT_EMAIL:-}" ] && [ -n "${JIRA_CONTRACT_TOKEN:-}" ] \
  && [ -n "${JIRA_CONTRACT_PROJECT:-}" ] && HAVE_JIRA=1
[ -n "${LINEAR_CONTRACT_KEY:-}" ] && HAVE_LINEAR=1
if [ "$HAVE_JIRA" = 0 ] && [ "$HAVE_LINEAR" = 0 ]; then
  echo "SKIP: no contract credentials (JIRA_CONTRACT_*, LINEAR_CONTRACT_KEY)"
  exit 0
fi
# The scratch tree only after the credential check: a skip writes nothing.
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$DIR/bin/lib/tracker.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
vendor_skip() { # vendor_skip <case> — rule 7: a vendor error is a vendor failure
  echo "SKIP: vendor failure $1"
  mkdir -p "$T/a/logs"
  HARNESS="$T/a" "$DIR/bin/alert-line.sh" --id tracker-contract "tracker-contract: connection-probe vendor failure at $1 (skipped, not a code failure)" >/dev/null 2>&1 || true
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::tracker-contract connection-probe: vendor failure at $1"
  echo "connection-probe contract: $PASS passed, $FAIL failed, stopped at $1 (vendor)"
  exit "$([ "$FAIL" = 0 ] && echo 0 || echo 1)"
}
export TRK_ERR="$T/err"

# K1
if [ "$HAVE_JIRA" = 1 ]; then
  rc=0
  ( tracker_load jira || exit 1
    trk_jira_context_fields "$JIRA_CONTRACT_SITE" "$JIRA_CONTRACT_EMAIL" "$JIRA_CONTRACT_TOKEN" \
      "$JIRA_CONTRACT_PROJECT" 'todo=To Do;closed=Done' || exit $?
    trk_jira_myself ) >"$T/k1.out" 2>"$T/k1.err" || rc=$?
  [ "$rc" = 75 ] && vendor_skip K1
  [ "$rc" = 0 ] && [ ! -s "$T/k1.out" ] && ok "K1 jira /myself rc 0, nothing on stdout" || bad "K1 jira /myself rc=$rc $(head -1 "$T/k1.err")"
else
  echo "SKIP: K1 no contract credentials (JIRA_CONTRACT_*)"
fi

if [ "$HAVE_LINEAR" = 1 ]; then
  # K2
  rc=0
  ( tracker_load linear || exit 1
    TRK_LINEAR_TOKEN="$LINEAR_CONTRACT_KEY" TRK_LINEAR_TOKEN_VAR=LINEAR_CONTRACT_KEY trk_linear_viewer ) >"$T/k2.out" 2>&1 || rc=$?
  [ "$rc" = 75 ] && vendor_skip K2
  [ "$rc" = 0 ] && [ ! -s "$T/k2.out" ] && ok "K2 linear viewer rc 0, nothing on stdout" || bad "K2 linear viewer rc=$rc"

  # K3: the read, then the probe end to end on a scratch harness with no worker
  # (JOBS_URL empty); its settings rows come from a fresh settings cache.
  BADKEY=lin_api_fixture_not_a_key_7924
  rc=0
  ( tracker_load linear || exit 1; TRK_LINEAR_TOKEN="$BADKEY" trk_linear_viewer ) >/dev/null 2>&1 || rc=$?
  [ "$rc" = 75 ] && vendor_skip K3
  [ "$rc" = 1 ] && ok "K3 a bad key is rc 1" || bad "K3 a bad key rc=$rc"
  H="$T/h"
  mkdir -p "$H/env" "$H/state" "$H/logs"
  for f in bin/connection-probe.sh bin/lib/tracker/linear.sh bin/jobs-client.sh bin/fleet-conf.sh bin/box-for.sh bin/box-name.sh; do
    ( cd "$DIR" && scratch_install_closure "$f" "$H" ) >/dev/null || { bad "K3 setup: $f"; f=""; break; }
  done
  for m in $(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$DIR/bin/jobs-client.sh"); do
    ( cd "$DIR" && scratch_install_closure "bin/lib/jobs/$m.sh" "$H" ) >/dev/null || bad "K3 setup: jobs module $m"
  done
  printf 'kbad o/kbad - - 1 box-k\n' > "$H/fleet.conf"
  printf 'LINEAR_API_KEY=%s\n' "$BADKEY" > "$H/env/kbad.env"
  printf 'JOBS_URL=\n' > "$H/env/global.env"
  jq -nc --argjson t 1798372800 '{fetched_at: $t, values: {"tracker_adapter.kbad": "linear", "tracker_linear.kbad.team": "CRO"}}' \
    > "$H/state/settings-cache.json"
  rc=0
  OUT=$(env -u HARNESS_SECRET HARNESS="$H" FLEET_CONF="$H/fleet.conf" LANE_GATE_NOW=1798372810 \
        CONNECTION_PROBE_NOW=1798372810 bash "$H/bin/connection-probe.sh" --dry-run kbad 2>"$T/k3.err") || rc=$?
  if [ "$rc" = 0 ] && jq -e '.ok == false and .adapter == "linear"' <<<"$OUT" >/dev/null 2>&1; then
    jq -e '.error | test("HTTP 4")' <<<"$OUT" >/dev/null 2>&1 || { jq -e '.error | test("rate limited")' <<<"$OUT" >/dev/null 2>&1 && vendor_skip K3; }
    ok "K3 the probe --dry-run prints ok:false"
  else
    bad "K3 probe rc=$rc out=$(head -c 300 <<<"$OUT")"
  fi
  grep -qF "$BADKEY" <<<"$OUT" && bad "K3 the probe printed the key" || ok "K3 the key is not in the output"
else
  echo "SKIP: K2 K3 no contract credentials (LINEAR_CONTRACT_KEY)"
fi

echo "connection-probe contract: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

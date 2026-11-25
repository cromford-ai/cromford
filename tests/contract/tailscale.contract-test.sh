#!/bin/bash
# contract-test
# tests/contract/tailscale.contract-test.sh — a REAL tailnet host through the
# seam bin/lib/vendor/tailscale.sh (BH-7975, slice BH-7939.1; iron law BH-7563
# rule 4). It is not in the PR loop `tests/*.sh tests/mc/*.sh`:
# .github/workflows/vendor-contract.yml runs it. It never joins a host.
#   C1  ts_ip "$TS_CONTRACT_HOST" passes ts_ip_ok
#   C2  ssh to an unreachable host is rc 1 and the key is not in the output
#   C3  an empty key variable is rc 3 with no ssh
# A vendor failure is not a code failure (rule 7): no TS_CONTRACT_HOST, no ssh,
# or an ssh TRANSPORT failure on C1 (a timeout, no route, a refused or
# unresolved connection) prints `SKIP vendor: <reason>`, writes one
# bin/lane-alert.sh --severity warn line (into the checkout's own logs/),
# prints a ::warning:: and exits 0. A host-key refusal, an auth refusal or any
# other ssh failure on C1 is a setup or code defect: C1 FAILS.
# Run: TS_CONTRACT_HOST=... bash tests/contract/tailscale.contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$DIR/bin/lib/vendor/tailscale.sh" || exit 1
export HARNESS_VENDOR_FAKE=0
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

skip() {
  echo "SKIP vendor: $1"
  HARNESS="$DIR" HARNESS_ENV_DIR="$DIR/env" "$DIR/bin/lane-alert.sh" --severity warn --id vendor-contract-tailscale \
    vendor-contract "tailscale contract suite skipped: $1" >/dev/null 2>&1
  echo "::warning::tailscale contract suite skipped: $1"
  exit 0
}

[ -n "${TS_CONTRACT_HOST:-}" ] || skip "TS_CONTRACT_HOST is not set"
command -v ssh >/dev/null 2>&1 || skip "ssh is not installed"
export TS_CALL_TIMEOUT_S=20

# C1 — the live host answers one tailnet address.
out=$(ts_ip "$TS_CONTRACT_HOST" 2>&1); rc=$?
if [ "$rc" != 0 ]; then
  case "$out" in
    *"Host key verification failed"*|*"Permission denied"*) ;;
    *"over ssh rc 124"*|*"Connection timed out"*|*"No route to host"*|*"Connection refused"*|*"Could not resolve hostname"*|*"Network is unreachable"*)
      skip "ts_ip: $out" ;;
  esac
fi
[ "$rc" = 0 ] && ts_ip_ok "$out" && ok || bad "C1 ts_ip rc $rc: $out"

# C2 — an unreachable host fails, and the key stays out of the output.
export TS_CONTRACT_KEY='tskey-auth-fixture-contract'
out=$(TS_CALL_TIMEOUT_S=5 ts_join unreachable.invalid TS_CONTRACT_KEY 2>&1); rc=$?
[ "$rc" = 1 ] && ok || bad "C2 unreachable rc $rc: $out"
case "$out" in *"$TS_CONTRACT_KEY"*) bad "C2 the key is in the output" ;; *) ok ;; esac

# C3 — an empty key: rc 3 before any ssh.
export TS_EMPTY_KEY=''
out=$(ts_join "$TS_CONTRACT_HOST" TS_EMPTY_KEY 2>&1); rc=$?
[ "$rc" = 3 ] && ok || bad "C3 empty key rc $rc: $out"

echo "tailscale.contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

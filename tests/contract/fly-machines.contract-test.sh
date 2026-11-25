#!/bin/bash
# contract-test
# tests/contract/fly-machines.contract-test.sh — the REAL Fly Machines API
# through the seam bin/lib/vendor/fly-machines.sh (BH-7975, slice BH-7939.1;
# iron law BH-7563 rule 4). It is not in the PR loop `tests/*.sh
# tests/mc/*.sh`: .github/workflows/vendor-contract.yml runs it. It reads an
# existing machine and never creates one.
#   C1  fm_state of FLY_CONTRACT_APP / FLY_CONTRACT_MACHINE is a state word
#   C2  fm_private_ip of the same machine passes its fdaa: check
#   C3  a bad token is rc 1 and the output does not hold it
#   C4  fm_create with the existing machine's name answers that id, and
#       `machine list` shows no new machine (no spend)
# A vendor failure is not a code failure (rule 7): no FLY_API_TOKEN or contract
# machine, no flyctl, a transport failure or a 429/5xx prints `SKIP vendor:
# <reason>`, writes one bin/lane-alert.sh --severity warn line (into the
# checkout's own logs/), prints a ::warning:: and exits 0.
# Run: FLY_API_TOKEN=... FLY_ORG=... FLY_CONTRACT_APP=... FLY_CONTRACT_MACHINE=... bash tests/contract/fly-machines.contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$DIR/bin/lib/vendor/fly-machines.sh" || exit 1
export HARNESS_VENDOR_FAKE=0
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

skip() {
  echo "SKIP vendor: $1"
  HARNESS="$DIR" HARNESS_ENV_DIR="$DIR/env" "$DIR/bin/lane-alert.sh" --severity warn --id vendor-contract-fly-machines \
    vendor-contract "fly-machines contract suite skipped: $1" >/dev/null 2>&1
  echo "::warning::fly-machines contract suite skipped: $1"
  exit 0
}
# vendor_error <text> — rc 0 when the error is the vendor's, not the code's.
vendor_error() { grep -qiE '429|too many requests|50[0-9]|timeout|timed out|connection|rc 124|no such host|dial tcp' <<<"$1"; }

[ -n "${FLY_API_TOKEN:-}" ] || skip "FLY_API_TOKEN is not set"
[ -n "${FLY_CONTRACT_APP:-}" ] && [ -n "${FLY_CONTRACT_MACHINE:-}" ] || skip "FLY_CONTRACT_APP or FLY_CONTRACT_MACHINE is not set"
fly_bin >/dev/null || skip "flyctl is not installed"
APP="$FLY_CONTRACT_APP"; MID="$FLY_CONTRACT_MACHINE"; export FM_PROJECT=contract

# C1 — the state word.
out=$(fm_state "$APP" "$MID" 2>&1); rc=$?
[ "$rc" = 0 ] || { vendor_error "$out" && skip "fm_state: $out"; bad "C1 fm_state rc $rc: $out"; }
[[ "$out" =~ ^[a-z_]{1,20}$ ]] && ok || bad "C1 state word: $out"

# C2 — the private address.
out=$(fm_private_ip "$APP" "$MID" 2>&1); rc=$?
[ "$rc" = 0 ] || { vendor_error "$out" && skip "fm_private_ip: $out"; bad "C2 fm_private_ip rc $rc: $out"; }
[[ "$out" =~ ^fdaa: ]] && ok || bad "C2 private ip: $out"

# C3 — a bad token is cut from the error.
BAD='fo1_bad-fixture-token-contract'
out=$(FLY_API_TOKEN="$BAD" FM_PROJECT=contract-bad fm_state "$APP" "$MID" 2>&1); rc=$?
[ "$rc" = 1 ] && ok || bad "C3 bad token rc $rc"
case "$out" in *"$BAD"*) bad "C3 the bad token is in the output" ;; *) ok ;; esac

# C4 — the dedup before the spend: the existing name answers its id.
# list <jq filter> — one read of the contract app's machines, token in env only.
list() { FLY_ACCESS_TOKEN="$FLY_API_TOKEN" timeout 60 "$(fly_bin)" machine list -a "$APP" --json 2>/dev/null | jq -r --arg id "$MID" "$1" 2>/dev/null; }
name=$(list '.[] | select(.id == $id) | .name') && [ -n "$name" ] || skip "machine list gave no name for $MID"
before=$(list 'length') || skip "machine list count"
out=$(fm_create "$APP" "$name" registry.fly.io/contract-never-run:v1 iad 2>&1); rc=$?
[ "$rc" = 0 ] || { vendor_error "$out" && skip "fm_create: $out"; bad "C4 fm_create rc $rc: $out"; }
[ "$out" = "$MID" ] && ok || bad "C4 fm_create answered '$out', want $MID"
after=$(list 'length') || skip "machine list count"
[ "$after" = "$before" ] && ok || bad "C4 machine count $before -> $after"

echo "fly-machines.contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

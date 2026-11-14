#!/bin/bash
# contract-test
# tests/contract/fly-anthropic-probe.bh-9677.contract-test.sh — the REAL Fly
# ssh call and the REAL GET /v1/models through the seam
# bin/lib/vendor/fly-anthropic-probe.sh fly_anthropic_key_probe (BH-9677;
# iron law BH-7563 rule 4). It is not in the PR loop `tests/*.sh tests/mc/*.sh`:
# .github/workflows/vendor-contract.yml runs it, one job at a time, on a push
# to main, nightly, and on a PR that touches bin/lib/vendor/** or
# tests/contract/**. GET /v1/models is not an inference call: no spend.
#   K1  the app's real secret KEY_PROBE_CONTRACT_SECRET (default
#       ANTHROPIC_API_KEY_KEYPROBE) answers 200
#   K2  a secret name that is not set on the app answers `nosecret`
#   K3  an app that does not exist is rc 1 (no marker)
#   K4  the stdout and stderr of K1-K3 hold no `sk-ant-` string
# A vendor failure is not a code failure (rule 7): no FLY_API_TOKEN, no
# KEY_PROBE_CONTRACT_APP, no flyctl, an ssh failure on the real app (rc 1 on
# K1 or K2), or an answer 429, 5xx or 000 prints `SKIP vendor: <reason>`,
# writes one bin/lane-alert.sh --severity warn line (into the checkout's own
# logs/, never a live harness), prints a ::warning:: and exits 0.
# Run: FLY_API_TOKEN=... KEY_PROBE_CONTRACT_APP=<app> \
#        bash tests/contract/fly-anthropic-probe.bh-9677.contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$DIR/bin/lib/vendor/fly-anthropic-probe.sh" || exit 1
# shellcheck source=../../bin/lib/endpoints.sh
. "$DIR/bin/lib/endpoints.sh" || exit 1
export HARNESS_VENDOR_FAKE=0
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

skip() {
  echo "SKIP vendor: $1"
  HARNESS="$DIR" HARNESS_ENV_DIR="$DIR/env" "$DIR/bin/lane-alert.sh" --severity warn --id vendor-contract-fly-anthropic-probe \
    vendor-contract "fly-anthropic-probe contract suite skipped: $1" >/dev/null 2>&1
  echo "::warning::fly-anthropic-probe contract suite skipped: $1"
  exit 0
}

[ -n "${FLY_API_TOKEN:-}" ] || skip "FLY_API_TOKEN is not set"
[ -n "${KEY_PROBE_CONTRACT_APP:-}" ] || skip "KEY_PROBE_CONTRACT_APP is not set"
fly_bin >/dev/null || skip "no flyctl on this runner"
APP="$KEY_PROBE_CONTRACT_APP"
SECRET="${KEY_PROBE_CONTRACT_SECRET:-ANTHROPIC_API_KEY_KEYPROBE}"
BASE=$(HARNESS="$DIR" endpoint_url anthropic 2>/dev/null) || BASE=""
[ -n "$BASE" ] || BASE="${ENDPOINT_ANTHROPIC:-}"
[ -n "$BASE" ] || skip "no Anthropic endpoint (endpoint_url anthropic)"
# The same defaults as the lib knobs load-project-key-probe.
CTO="${LOAD_PROJECT_KEY_PROBE_TIMEOUT_S:-30}" STO="${LOAD_PROJECT_KEY_PROBE_SSH_TIMEOUT_S:-120}"
ALL=""

# K1 — the real secret answers 200.
out=$(fly_anthropic_key_probe "$APP" "$SECRET" "$BASE" "$CTO" "$STO" 2>&1); rc=$?
ALL+="$out"
[ "$rc" = 0 ] || skip "K1 the probe could not run on $APP (rc $rc)"
case "$out" in 429|5??|000) skip "K1 Anthropic answered $out" ;; esac
eq "K1 the real secret answers 200" "$out" 200

# K2 — a secret name that is not set answers nosecret.
out=$(fly_anthropic_key_probe "$APP" ANTHROPIC_API_KEY_KEYPROBE_UNSET_CONTRACT "$BASE" "$CTO" "$STO" 2>&1); rc=$?
ALL+="$out"
[ "$rc" = 0 ] || skip "K2 the probe could not run on $APP (rc $rc)"
eq "K2 an unset secret answers nosecret" "$out" nosecret

# K3 — an app that does not exist is rc 1.
out=$(fly_anthropic_key_probe "keyprobe-contract-no-such-app-$$" "$SECRET" "$BASE" "$CTO" "$STO" 2>&1); rc=$?
ALL+="$out"
eq "K3 an app that does not exist is rc 1" "$rc" 1

# K4 — no key in any output.
case "$ALL" in *sk-ant-*) bad "K4 an sk-ant- string is in the output" ;; *) ok ;; esac

echo "fly-anthropic-probe contract: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

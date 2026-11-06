#!/bin/bash
# contract-test
# tests/contract/resend.bh-8894.contract-test.sh — the REAL Resend send through
# the seam bin/lib/vendor/resend.sh resend_send (BH-8894; iron law BH-7563
# rule 4). It is not in the PR loop `tests/*.sh tests/mc/*.sh`:
# .github/workflows/vendor-contract.yml runs it, one job at a time, on a push
# to main, nightly, and on a PR that touches bin/lib/vendor/** or
# tests/contract/**. No message is delivered to anyone.
#   C1  a bad key answers no .id and a statusCode of 401 or 403, and the
#       output does not hold the key
#   C2  the real key with to = not-an-address answers no .id and a 4xx
#       statusCode (Resend validates the recipient before it sends)
#   C3  the same call in fake mode answers fake-email-0001 and adds 0 lines to
#       VENDOR_CALL_LOG
# A vendor failure is not a code failure (rule 7): no RESEND_API_KEY, a curl
# failure, an answer that is not JSON, or a 429/5xx prints
# `SKIP vendor: <reason>`, writes one bin/lane-alert.sh --severity warn line
# (into the checkout's own logs/, never a live harness), prints a ::warning::
# and exits 0.
# Run: RESEND_API_KEY=... bash tests/contract/resend.bh-8894.contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$DIR/bin/lib/vendor/resend.sh" || exit 1
export HARNESS_VENDOR_FAKE=0
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

skip() {
  echo "SKIP vendor: $1"
  HARNESS="$DIR" HARNESS_ENV_DIR="$DIR/env" "$DIR/bin/lane-alert.sh" --severity warn --id vendor-contract-resend \
    vendor-contract "resend contract suite skipped: $1" >/dev/null 2>&1
  echo "::warning::resend contract suite skipped: $1"
  exit 0
}
# vendor_error <body> — print why, rc 0, when the answer is a vendor failure.
vendor_error() {
  local code
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$1" || { echo "the answer is not JSON"; return 0; }
  code=$(jq -r '.statusCode // empty' <<<"$1")
  case "$code" in 429|5??) echo "Resend answered $code"; return 0 ;; esac
  return 1
}

[ -n "${RESEND_API_KEY:-}" ] || skip "RESEND_API_KEY is not set"
FROM="contract@example.test"

# C1 — a bad key is a Resend error, and the key is not in the output.
RS_BAD='re_bad_fixture_key'
out=$(resend_send RS_BAD "$FROM" "nobody@example.test" "contract" "contract" 2>&1); rc=$?
[ "$rc" = 0 ] || skip "bad-key call: $out"
why=$(vendor_error "$out") && skip "bad-key call: $why"
eq "C1 bad key no id" "$(jq -r '.id // empty' <<<"$out")" ""
case "$(jq -r '.statusCode' <<<"$out")" in 401|403) ok ;; *) bad "C1 bad key statusCode: $out" ;; esac
case "$out" in *"$RS_BAD"*) bad "C1 the bad key is in the output" ;; *) ok ;; esac

# C2 — the body reaches Resend: an invalid recipient is refused.
out=$(resend_send RESEND_API_KEY "$FROM" "not-an-address" "contract" "contract" 2>&1); rc=$?
[ "$rc" = 0 ] || skip "invalid-to call: $out"
why=$(vendor_error "$out") && skip "invalid-to call: $why"
eq "C2 invalid to no id" "$(jq -r '.id // empty' <<<"$out")" ""
case "$(jq -r '.statusCode' <<<"$out")" in 4??) ok ;; *) bad "C2 invalid to statusCode: $out" ;; esac
case "$out" in *"$RESEND_API_KEY"*) bad "C2 the key is in the output" ;; *) ok ;; esac

# C3 — fake mode answers the seed and logs no real call.
LOG=$(mktemp "${TMPDIR:-/tmp}/resend-contract-calls.XXXXXX") || skip "cannot make a temp file"
out=$(HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$DIR/tests/fixtures/vendor-fake" VENDOR_CALL_LOG="$LOG" \
  resend_send RESEND_API_KEY "$FROM" "not-an-address" "contract" "contract" 2>&1)
eq "C3 fake id" "$(jq -r '.id' <<<"$out" 2>/dev/null)" fake-email-0001
eq "C3 fake calls" "$(grep -c . "$LOG")" 0
rm -f "$LOG"

echo "resend.contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

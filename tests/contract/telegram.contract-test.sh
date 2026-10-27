#!/bin/bash
# contract-test
# tests/contract/telegram.contract-test.sh — the REAL Telegram Bot API through
# the seam bin/lib/vendor/telegram.sh (BH-7974, slice BH-7939.0; iron law
# BH-7563 rule 4). It is not in the PR loop `tests/*.sh tests/mc/*.sh`:
# .github/workflows/vendor-contract.yml runs it, one job at a time, on a push to
# main, nightly, and on a PR that touches bin/lib/vendor/** or tests/contract/**.
#   C1  getMe answers .ok==true and .result.is_bot==true
#   C2  getUpdates answers .ok==true and an array .result, and
#       tg_latest_chat_id is rc 0 or rc 4 (never rc 1)
#   C3  a bad token is rc 1 and the output does not hold it
# A vendor failure is not a code failure (rule 7): no TELEGRAM_BOT_TOKEN, a curl
# failure, an answer that is not JSON, or a 429/5xx prints
# `SKIP vendor: <reason>`, writes one bin/lane-alert.sh --severity warn line
# (into the checkout's own logs/, never a live harness), prints a ::warning::
# and exits 0.
# Run: TELEGRAM_BOT_TOKEN=... bash tests/contract/telegram.contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$DIR/bin/lib/vendor/telegram.sh" || exit 1
export HARNESS_VENDOR_FAKE=0
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

skip() {
  echo "SKIP vendor: $1"
  HARNESS="$DIR" HARNESS_ENV_DIR="$DIR/env" "$DIR/bin/lane-alert.sh" --severity warn --id vendor-contract-telegram \
    vendor-contract "telegram contract suite skipped: $1" >/dev/null 2>&1
  echo "::warning::telegram contract suite skipped: $1"
  exit 0
}
# vendor_error <body> — print why, rc 0, when the answer is a vendor failure.
vendor_error() {
  local code
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$1" || { echo "the answer is not JSON"; return 0; }
  code=$(jq -r '.error_code // empty' <<<"$1")
  case "$code" in 429|5??) echo "Telegram answered $code"; return 0 ;; esac
  return 1
}

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || skip "TELEGRAM_BOT_TOKEN is not set"

# C1 — getMe.
body=$(tg_call TELEGRAM_BOT_TOKEN getMe 2>&1) || skip "getMe: $body"
why=$(vendor_error "$body") && skip "getMe: $why"
eq "C1 getMe ok" "$(jq -r '.ok' <<<"$body")" true
eq "C1 getMe is_bot" "$(jq -r '.result.is_bot' <<<"$body")" true

# C2 — getUpdates shape, and the chat-id pick on the live answer.
body=$(tg_call TELEGRAM_BOT_TOKEN getUpdates 2>&1) || skip "getUpdates: $body"
why=$(vendor_error "$body") && skip "getUpdates: $why"
eq "C2 getUpdates ok" "$(jq -r '.ok' <<<"$body")" true
eq "C2 result is an array" "$(jq -r '.result | type' <<<"$body")" array
out=$(tg_latest_chat_id TELEGRAM_BOT_TOKEN 2>&1); rc=$?
case "$rc" in 0|4) ok ;; *) bad "C2 tg_latest_chat_id rc $rc: $out" ;; esac

# C3 — a bad token is a Telegram error, and the token is cut from the output.
TG_BAD='123:bad-fixture-token'
out=$(tg_latest_chat_id TG_BAD 2>&1); rc=$?
case "$out" in *"curl rc"*) skip "bad-token call: $out" ;; esac
eq "C3 bad token rc 1" "$rc" 1
case "$out" in *"$TG_BAD"*) bad "C3 the bad token is in the output: $out" ;; *) ok ;; esac

echo "telegram.contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

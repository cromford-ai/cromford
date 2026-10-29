#!/bin/bash
# contract-test
# tests/contract/telegram-send.bh-8650.contract-test.sh — the REAL Telegram
# sendMessage through the seam bin/lib/vendor/telegram.sh tg_send_message
# (BH-8650; iron law BH-7563 rule 4). It is not in the PR loop
# `tests/*.sh tests/mc/*.sh`: .github/workflows/vendor-contract.yml runs it, one
# job at a time, on a push to main, nightly, and on a PR that touches
# bin/lib/vendor/** or tests/contract/**.
#   C1  chat_id 0 with an inline keyboard answers .ok == false and
#       .error_code == 400 (chat 0 delivers no message to anyone)
#   C2  a bad token is rc 0 with .ok == false, .error_code 401 or 404, and the
#       output does not hold the token
# A vendor failure is not a code failure (rule 7): no TELEGRAM_BOT_TOKEN, a curl
# failure, an answer that is not JSON, or a 429/5xx prints
# `SKIP vendor: <reason>`, writes one bin/lane-alert.sh --severity warn line
# (into the checkout's own logs/, never a live harness), prints a ::warning::
# and exits 0.
# Run: TELEGRAM_BOT_TOKEN=... bash tests/contract/telegram-send.bh-8650.contract-test.sh
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
  HARNESS="$DIR" HARNESS_ENV_DIR="$DIR/env" "$DIR/bin/lane-alert.sh" --severity warn --id vendor-contract-telegram-send \
    vendor-contract "telegram sendMessage contract suite skipped: $1" >/dev/null 2>&1
  echo "::warning::telegram sendMessage contract suite skipped: $1"
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
MARKUP='{"inline_keyboard":[[{"text":"x","callback_data":"pm:a:x"}]]}'

# C1 — the form fields reach Telegram: chat 0 is refused as a bad request.
body=$(tg_send_message TELEGRAM_BOT_TOKEN 0 "" "contract" "$MARKUP" 2>&1) || skip "sendMessage: $body"
why=$(vendor_error "$body") && skip "sendMessage: $why"
eq "C1 chat 0 ok" "$(jq -r '.ok' <<<"$body")" false
eq "C1 chat 0 error_code" "$(jq -r '.error_code' <<<"$body")" 400

# C2 — a bad token is a Telegram error, and the token is not in the output.
TG_BAD='123:bad-fixture-token'
out=$(tg_send_message TG_BAD 0 "" "contract" "$MARKUP" 2>&1); rc=$?
case "$out" in *"curl rc"*) skip "bad-token call: $out" ;; esac
eq "C2 bad token rc 0" "$rc" 0
eq "C2 bad token ok" "$(jq -r '.ok' <<<"$out" 2>/dev/null)" false
case "$(jq -r '.error_code' <<<"$out" 2>/dev/null)" in 401|404) ok ;; *) bad "C2 bad token error_code: $out" ;; esac
case "$out" in *"$TG_BAD"*) bad "C2 the bad token is in the output" ;; *) ok ;; esac

echo "telegram-send.contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

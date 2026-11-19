#!/bin/bash
# contract-test
# tests/contract/mergify.bh-9695.contract-test.sh — the REAL Mergify
# activity-log read through the seam bin/lib/vendor/mergify.sh
# mergify_queue_leave_events (BH-9695; iron law BH-7563 rule 4). It is not in
# the PR loop `tests/*.sh tests/mc/*.sh`: .github/workflows/vendor-contract.yml
# runs it, one job at a time, on a push to main, nightly, and on a PR that
# touches bin/lib/vendor/** or tests/contract/**. It only reads.
#   C1  a bad token answers rc 1 with HTTP 401 or 403, and the output does not
#       hold the token
#   C2  the real token on example-org/cromford and a recent PR
#       (MERGIFY_CONTRACT_PR, default #9811) answers rc 0 with `.events` an
#       array
#   C3  each event in C2 with type action.queue.leave has a `metadata` object
#       with the key `dequeue_code` (the field mc_eu_event_cause reads); SKIP
#       the case when the window holds none
#   C4  the same call in fake mode answers the seed and adds 0 lines to
#       VENDOR_CALL_LOG
#   C5  MERGIFY_EVENTS_PER_PAGE=abc reads as 10 (the fallback)
# A vendor failure is not a code failure (rule 7): no MERGIFY_API_TOKEN, a
# curl failure, or a 429/5xx prints `SKIP vendor: <reason>`, writes one
# bin/lane-alert.sh --severity warn line (into the checkout's own logs/, never
# a live harness), prints a ::warning:: and exits 0.
# Run: MERGIFY_API_TOKEN=... bash tests/contract/mergify.bh-9695.contract-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$DIR/bin/lib/vendor/mergify.sh" || exit 1
export HARNESS_VENDOR_FAKE=0
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
SLUG="${MERGIFY_CONTRACT_SLUG:-example-org/cromford}"

skip() {
  echo "SKIP vendor: $1"
  HARNESS="$DIR" HARNESS_ENV_DIR="$DIR/env" "$DIR/bin/lane-alert.sh" --severity warn --id vendor-contract-mergify \
    vendor-contract "mergify contract suite skipped: $1" >/dev/null 2>&1
  echo "::warning::mergify contract suite skipped: $1"
  exit 0
}
# vendor_error <stderr> — print why, rc 0, when the failure is the vendor's.
vendor_error() {
  case "$1" in
    *"curl rc "[1-9]*) echo "curl failed: ${1:0:200}"; return 0 ;;
    *"HTTP 429"*|*"HTTP 5"[0-9][0-9]*) echo "Mergify answered: ${1:0:200}"; return 0 ;;
  esac
  return 1
}

[ -n "${MERGIFY_API_TOKEN:-}" ] || skip "MERGIFY_API_TOKEN is not set"
command -v jq >/dev/null 2>&1 || skip "jq is not installed"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"
ERR=$(mktemp "${TMPDIR:-/tmp}/mergify-contract-err.XXXXXX") || skip "cannot make a temp file"
trap 'rm -f "$ERR"' EXIT

# C1 — a bad token is a Mergify refusal, and the token is not in the output.
MG_BAD='mgf_bad_fixture_token'
out=$(mergify_queue_leave_events MG_BAD "$SLUG" 1 2>"$ERR"); rc=$?
err=$(cat "$ERR")
why=$(vendor_error "$err") && skip "bad-token call: $why"
eq "C1 bad token rc" "$rc" 1
case "$err" in *"HTTP 401"*|*"HTTP 403"*) ok ;; *) bad "C1 bad token HTTP code: $err" ;; esac
case "$out$err" in *"$MG_BAD"*) bad "C1 the bad token is in the output" ;; *) ok ;; esac

# C2 — the real token reads the events of a recent PR.
# #9811 (BH-9795) went through the Mergify queue on 2026-11-19. No GitHub read:
# Mergify is the one vendor this suite calls.
NUM="${MERGIFY_CONTRACT_PR:-9811}"
[[ "$NUM" =~ ^[0-9]+$ ]] || skip "MERGIFY_CONTRACT_PR is not a PR number"
out=$(mergify_queue_leave_events MERGIFY_API_TOKEN "$SLUG" "$NUM" 2>"$ERR"); rc=$?
err=$(cat "$ERR")
why=$(vendor_error "$err") && skip "events call: $why"
eq "C2 events rc (#$NUM: $err)" "$rc" 0
eq "C2 .events is an array" "$(jq -r '.events | type' <<<"$out" 2>/dev/null)" array
case "$out$err" in *"$MERGIFY_API_TOKEN"*) bad "C2 the token is in the output" ;; *) ok ;; esac

# C3 — the fields mc_eu_event_cause reads are there.
nl=$(jq '[.events[]? | select(.type == "action.queue.leave")] | length' <<<"$out" 2>/dev/null)
if [ "${nl:-0}" -gt 0 ]; then
  eq "C3 every queue.leave event has metadata.dequeue_code" \
    "$(jq '[.events[] | select(.type == "action.queue.leave") | select((.metadata | type) == "object" and (.metadata | has("dequeue_code")))] | length' <<<"$out")" "$nl"
else
  echo "SKIP C3: PR #$NUM has no action.queue.leave event in its window"
fi

# C4 — fake mode answers the seed and logs no real call.
LOG=$(mktemp "${TMPDIR:-/tmp}/mergify-contract-calls.XXXXXX") || skip "cannot make a temp file"
out=$(HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$DIR/tests/fixtures/vendor-fake" VENDOR_CALL_LOG="$LOG" \
  mergify_queue_leave_events MERGIFY_API_TOKEN "$SLUG" 1 2>&1)
eq "C4 fake dequeue_code" "$(jq -r '.events[0].metadata.dequeue_code' <<<"$out" 2>/dev/null)" CHECKS_FAILED
eq "C4 fake calls" "$(grep -c . "$LOG")" 0
rm -f "$LOG"

# C5 — a bad page-size knob reads as its fallback.
eq "C5 per_page fallback" "$(_mg_int abc 10 1 100)" 10

echo "mergify.contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

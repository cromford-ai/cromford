#!/bin/bash
# tests/unblock-subject-kinds.bh-8498-test.sh — BH-8498: every subject_kind a
# Tackler collector emits is one the claim route accepts.
#
# The route (worker/jobs/src/routes/unblock-decisions.js, SUBJECT_KINDS) and
# the unblock_decisions table CHECK accept a fixed set. On 2026-10-26 the infra
# collector emitted source, pool and ticket, so POST
# /api/unblock/decisions/claim answered 400 {"error":"subject_kind"} for every
# infra stall and act mode could not claim one.
#
# K1 the route's set is readable.
# K2 every literal `subject_kind: "<word>"` in bin/lib/unblock/collectors/*.sh
#    is in that set.
# K3 a collector that emits a word outside the set is red (a mutated copy).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-subject-kinds.bh-8498-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTE="$DIR/worker/jobs/src/routes/unblock-decisions.js"

# route_kinds <route-file> — the words in `const SUBJECT_KINDS = new Set([...])`.
route_kinds() {
  grep -E '^const SUBJECT_KINDS = new Set\(\[' "$1" | grep -oE '"[a-z]+"' | tr -d '"' | sort -u
}

# bad_kinds <collectors-dir> <kinds> — each emitted word not in <kinds>.
bad_kinds() {
  local k
  for k in $(grep -ohE 'subject_kind: "[a-z]+"' "$1"/*.sh | grep -oE '"[a-z]+"' | tr -d '"' | sort -u); do
    grep -qx "$k" <<<"$2" || echo "$k"
  done
}

KINDS=$(route_kinds "$ROUTE")
[ "$(wc -l <<<"$KINDS" | tr -d ' ')" -ge 3 ] && ok || bad "K1 could not read SUBJECT_KINDS from $ROUTE (got [$KINDS])"

OUT=$(bad_kinds "$DIR/bin/lib/unblock/collectors" "$KINDS")
[ -z "$OUT" ] && ok || bad "K2 collectors emit subject_kind words the claim route refuses: $(tr '\n' ' ' <<<"$OUT")(accepted: $(tr '\n' ' ' <<<"$KINDS"))"

mkdir -p "$T/collectors"
# scratch-closure-allow: the copies are scanned as text by bad_kinds, never sourced or run
cp "$DIR"/bin/lib/unblock/collectors/*.sh "$T/collectors/"
printf '%s\n' '# mutated: {subject_kind: "pool"}' >> "$T/collectors/infra.sh"
OUT=$(bad_kinds "$T/collectors" "$KINDS")
[ "$OUT" = pool ] && ok || bad "K3 a mutated collector emitting pool must be red, got [$OUT]"

echo "unblock-subject-kinds.bh-8498: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

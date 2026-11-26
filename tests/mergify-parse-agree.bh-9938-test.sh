#!/bin/bash
# tests/mergify-parse-agree.bh-9938-test.sh — BH-9938 slice C1 (C0 review note
# 5): the PR record's Mergify payload and dequeue-watch's own GitHub parse give
# the same values for one body.
#
#   A1  dqw_parse_payload_md (bin/lib/dequeue-watch/attribute.sh) on the shared
#       fixture tests/fixtures/mergify/bh-9938-parse.md prints draft 111, run
#       901, the first left sha and bullet-a,bullet-b: the 4 values
#       worker/jobs/test/pr-record-mergify-parse.bh-9938.test.js (P1) asserts
#       the worker stores for the same file.
#   A2  dqw_payload_record (bin/lib/prr-shadow.d/dequeue-watch.sh) on a record
#       that holds those stored values prints the same 4 fields.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mergify-parse-agree.bh-9938-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FX="$DIR/tests/fixtures/mergify/bh-9938-parse.md"
[ -r "$FX" ] || { echo "FAIL: fixture $FX missing"; exit 1; }
LEFT=1111111111111111111111111111111111111111
WANT=$(printf '111\t901\t%s\tbullet-a,bullet-b' "$LEFT")

# ── A1: the GitHub-side parse ────────────────────────────────────────────────
GOT=$(bash -c '. "$1/bin/lib/dequeue-watch/attribute.sh" 2>/dev/null || exit 9; dqw_parse_payload_md "$(cat "$2")"' _ "$DIR" "$FX")
eq "A1 dqw_parse_payload_md on the shared fixture" "$GOT" "$WANT"

# ── A2: the record side, on the values the worker stores for that body ────────
REC=$(jq -nc --arg l "$LEFT" '{state: "dequeued", code: "CHECKS_FAILED", draft_pr: 111, failing_checks: ["bullet-a", "bullet-b"],
  left_sha: $l, comment_id: 8101, at: "2026-11-26T11:50:00Z", run_id: 901, updated_at: "2026-11-26T11:50:00Z"}')
OUT=$(REC="$REC" HARNESS="$T" bash -c '
  pr_record_mergify() { printf "%s\n" "$REC"; }
  vs_context() { echo lead-verdict; }
  . "$1/bin/lib/prr-shadow.d/dequeue-watch.sh" 2>/dev/null || exit 9
  dqw_payload_record "$2/rec.tsv" o/r 5 || exit 8
  cut -f4- "$2/rec.tsv"' _ "$DIR" "$T")
eq "A2 dqw_payload_record on the stored values" "$OUT" "$WANT"

echo "mergify-parse-agree.bh-9938: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
# BH-10485: a comments-only reader (pr-state-reconcile, hold_check_thread)
# whose issue has NO row in the issue record seeds the row once, so the next
# read is a record hit instead of a GitHub read on every pass.
#   N1 no row: the comments read misses, ONE issues/N read follows, and ONE
#      whole-thread PUT with base_rev 0 (issue object + comments) is written
#   N2 no row, the issues/N read fails: no PUT; the verdict is the comments
#      read's, unchanged
#   N3 a stored row (rev 3, stale): the comments-only write-back as before
#      (issue null, base_rev 3), no issues/N read
#   N4 step off: GitHub only, no record read, no PUT
#   N5 the seed read carries GH_REASON=record-miss:no-record
#
# No vendor is called (BH-7563): gh_rest and _jobs_req are local stubs.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/issue-record-seed.bh-10485-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/logs" "$H/bin" "$T/fakebin" "$T/tmp"
export HARNESS="$H" TMPDIR="$T/tmp"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"; export PATH="$T/fakebin:$PATH"

# shellcheck source=bin/lib/hold.sh
. "$DIR/bin/lib/hold.sh" || exit 1
# shellcheck source=bin/lib/prr-shadow.sh
. "$DIR/bin/lib/prr-shadow.sh" || exit 1
# shellcheck source=bin/lib/issue-record.sh
. "$DIR/bin/lib/issue-record.sh" || exit 1

AT1='2026-11-27T04:00:00Z'; AT2='2026-11-27T05:00:00Z'
# THE GITHUB STUB. $T/issue-fail = the issues/N read fails. Each call logs
# its path and the GH_REASON it carried.
gh_rest() {
  printf '%s %s reason=%s\n' "$1" "$2" "${GH_REASON:-}" >> "$T/gh.txt"
  GH_REST_STATUS=200
  case "$2" in
    repos/o/r/issues/*/comments*)
      jq -nc --arg a "$AT1" '[{id: 11, body: "HOLD", created_at: $a, updated_at: $a, user: {login: "operator", type: "User"}}]' ;;
    repos/o/r/issues/[0-9]*)
      [ -f "$T/issue-fail" ] && { GH_REST_STATUS=502; return 75; }
      jq -nc --argjson n "${2##*/}" --arg a "$AT2" '{number: $n, state: "open", title: "T", body: "b", labels: [{name: "ai-build"}], updated_at: $a}' ;;
    *) GH_REST_STATUS=404; return 44 ;;
  esac
  return 0
}
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/jobs.txt"
  case "$1 $2" in
    "GET /api/issue-records?"*) [ -f "$T/rec.json" ] && { cat "$T/rec.json"; return 0; }; return 1 ;;
    "PUT /api/issue-records") printf '%s\n' "$3" >> "$T/put.json"; echo '{"applied":true,"rev":1}'; return 0 ;;
    "POST /api/issue-record-syncs/claim") echo '{"due":false}'; return 0 ;;
  esac
  return 1
}
norow() { jq -nc --arg a "$AT2" '{row: null, comments: [], why: "no-record", sync: {synced_at: $a, mark: $a, age_s: 10}}' > "$T/rec.json"; }
stalerow() {
  jq -nc --arg a1 "$AT1" --arg a2 "$AT2" '{row: {rev: 3, state: "open", title: "T", body: "b", labels: ["ai-build"], gh_updated_at: $a2},
    comments: [], why: "stale", sync: {synced_at: $a2, mark: $a2, age_s: 10}}' > "$T/rec.json"
}
reset() { scratch_rm "$H/state/issue-record-claim"; rm -f "$T"/gh.txt "$T"/jobs.txt "$T"/put.json "$T"/rec.json "$T"/issue-fail "$H/logs/prr-shadow.log"; }
cnt() { if [ -f "$2" ]; then grep -cF -- "$1" "$2"; else echo 0; fi; }
IRR_LANE=pr-state-reconcile

# ── N1 no row: seed once ───────────────────────────────────────────────────
reset; norow; IRR_STEP=record
out=$(hold_check_thread o/r 5); rc=$?
eq "N1 rc (held)" "$rc" 1
eq "N1 comments reads" "$(cnt 'issues/5/comments' "$T/gh.txt")" 1
eq "N1 issues/N reads" "$(cnt 'GET repos/o/r/issues/5 ' "$T/gh.txt")" 1
eq "N1 PUT count" "$(cnt '' "$T/put.json")" 1
eq "N1 PUT base 0 + issue + comments" "$(jq -c '[.base_rev, .number, .issue.state, (.comments | length)]' "$T/put.json" 2>/dev/null)" '[0,5,"open",1]'

# ── N5 the seed read says why ──────────────────────────────────────────────
eq "N5 seed reason" "$(grep -F 'GET repos/o/r/issues/5 ' "$T/gh.txt" | grep -c 'reason=record-miss:no-record')" 1

# ── N2 no row, issues/N fails: no PUT, same verdict ────────────────────────
reset; norow; touch "$T/issue-fail"; IRR_STEP=record
out=$(hold_check_thread o/r 5); rc=$?
eq "N2 rc (held)" "$rc" 1
eq "N2 no PUT" "$(cnt '' "$T/put.json")" 0

# ── N3 stored row: comments-only write-back as before ──────────────────────
reset; stalerow; IRR_STEP=record
out=$(hold_check_thread o/r 5); rc=$?
eq "N3 rc (held)" "$rc" 1
eq "N3 no issues/N read" "$(cnt 'GET repos/o/r/issues/5 ' "$T/gh.txt")" 0
eq "N3 PUT comments-only base 3" "$(jq -c '[.base_rev, .issue]' "$T/put.json" 2>/dev/null)" '[3,null]'

# ── N4 step off: GitHub only ───────────────────────────────────────────────
reset; norow; IRR_STEP=off
out=$(hold_check_thread o/r 5); rc=$?
eq "N4 rc (held)" "$rc" 1
eq "N4 no jobs call" "$(cnt '' "$T/jobs.txt")" 0
eq "N4 no PUT" "$(cnt '' "$T/put.json")" 0
eq "N4 no issues/N read" "$(cnt 'GET repos/o/r/issues/5 ' "$T/gh.txt")" 0

echo "issue-record-seed.bh-10485: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

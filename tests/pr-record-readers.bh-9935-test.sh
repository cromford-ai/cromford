#!/bin/bash
# contract-test: R5 pins the head_commit PUT body against the worker suite fixture (worker/jobs/test/fixtures/pr-record-files.bh-9935.json); every other case asserts fields
# tests/pr-record-readers.bh-9935-test.sh — BH-9935 (BH-9926.3): the record
# readers pr_record_statuses, pr_record_mergify and pr_record_head_commit_time
# in bin/lib/pr-record.sh. The REAL lib runs against the in-file record store
# and the gh_rest double of tests/lib/pr-record-store.bh-9935.sh. curl and gh
# are PATH shims that log and fail, so a real host is never called.
#
#   R1  pr_record_statuses prints the head's entries (the record's head_sha by default)
#   R2  no record: rc 1, `statuses … miss=unknown`
#   R3  entries for an older head are filtered out: rc 1, `miss=none`
#   R3b no head_sha on the row and no head given: rc 1, `miss=no-head`
#   R4  pr_record_head_commit_time hit: the time, 0 GitHub calls
#   R5  a miss: 1 commits/<head> call + 1 PUT (the fixture body), then the next call is a hit
#   R5b GitHub 404: rc 44, nothing printed; GitHub fails: rc 75, nothing printed, no PUT
#   R6  pr_record_mergify prints the object; rc 1 `miss=none` when NULL
#   R7  a failed jobs GET: rc 1 `unreadable`, 0 GitHub calls, for the record-only readers
#   R8  bad args: rc 2, no request
#   B1  0 calls to a real host
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-record-readers.bh-9935-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/pr-record-store.bh-9935.sh
. "$(dirname "$0")/lib/pr-record-store.bh-9935.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

H="$T/h"; mkdir -p "$H/logs" "$T/bin"
( cd "$REPO" && scratch_install_closure bin/lib/pr-record.sh "$H" ) >/dev/null 2>&1 || { echo "setup: could not install bin/lib/pr-record.sh"; exit 1; }
for x in curl gh; do printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/real-host.log"\nexit 7\n' "$x" "$T" > "$T/bin/$x"; done
chmod +x "$T/bin/"*; : > "$T/real-host.log"
PATH="$T/bin:$PATH"
export HARNESS="$H"
unset JOBS_URL GH_TOKEN
# shellcheck source=bin/lib/pr-record.sh
. "$H/bin/lib/pr-record.sh"
LOG="$H/logs/pr-record.log"
A=$(printf 'a%.0s' $(seq 40)); B=$(printf 'b%.0s' $(seq 40))
R=o/bh9935-readers
run() { "$@" > "$T/stdout" 2>/dev/null; echo $? > "$T/rc"; }
out() { cat "$T/stdout"; }
rc()  { cat "$T/rc"; }

# ---- R1-R3: statuses -------------------------------------------------------------
prs_set "$R" 1 "$(jq -nc --arg a "$A" --arg b "$B" '{repo:"o/bh9935-readers", number:1, state:"open", head_sha:$a,
  statuses: {"lead-verdict": {state:"success", description:"APPROVE", sha:$a, at:"2026-11-24T11:00:00Z"},
             "prequeue-verdict": {state:"pending", description:"run", sha:$b, at:"2026-11-24T10:00:00Z"}}}')"
run pr_record_statuses "$R" 1
eq "R1: rc 0" "$(rc)" 0
eq "R1: only the head's entries" "$(out | jq -c 'keys')" '["lead-verdict"]'
eq "R1: the entry" "$(out | jq -r '."lead-verdict" | "\(.state) \(.description) \(.at)"')" "success APPROVE 2026-11-24T11:00:00Z"
run pr_record_statuses "$R" 1 "$(tr a-f A-F <<<"$B")"
eq "R1: an asked head (any case) picks its own entries" "$(out | jq -c 'keys')" '["prequeue-verdict"]'
run pr_record_statuses "$R" 2
eq "R2: no record is rc 1" "$(rc):$(out)" "1:"
grep -q "statuses $R#2 miss=unknown" "$LOG" && ok "R2: miss=unknown logged" || bad "R2: log: $(cat "$LOG")"
prs_set "$R" 3 "$(jq -nc --arg a "$A" --arg b "$B" '{repo:"o/bh9935-readers", number:3, head_sha:$b,
  statuses: {"lead-verdict": {state:"success", description:"APPROVE", sha:$a, at:"2026-11-24T11:00:00Z"}}}')"
run pr_record_statuses "$R" 3
eq "R3: an older head's entry is not printed as current" "$(rc):$(out)" "1:"
grep -q "statuses $R#3 miss=none" "$LOG" && ok "R3: miss=none logged" || bad "R3: log: $(tail -1 "$LOG")"
prs_set "$R" 4 '{"repo":"o/bh9935-readers","number":4,"statuses":null}'
run pr_record_statuses "$R" 4
eq "R3b: no head is rc 1" "$(rc)" 1
grep -q "statuses $R#4 miss=no-head" "$LOG" && ok "R3b: miss=no-head logged" || bad "R3b: log: $(tail -1 "$LOG")"

# ---- R4-R5: head commit time -------------------------------------------------------
prs_set "$R" 5 "$(jq -nc --arg a "$A" '{repo:"o/bh9935-readers", number:5, head_sha:$a, head_commit:{sha:$a, at:"2026-11-24T09:00:00Z"}}')"
run pr_record_head_commit_time "$R" 5 "$A"
eq "R4: a hit prints the time" "$(rc):$(out)" "0:2026-11-24T09:00:00Z"
eq "R4: 0 GitHub calls" "$(prs_gh /commits/)" 0
# R5: the record holds A's time; the head is now B.
jq -nc '{sha:"x", commit:{committer:{date:"2026-11-24T10:00:00Z"}, author:{date:"2026-11-01T00:00:00Z"}}}' > "$PRS/gh/commit-$B.json"
P0=$(prs_puts)
run pr_record_head_commit_time "$R" 5 "$B"
eq "R5: a miss reads GitHub and prints the committer date" "$(rc):$(out)" "0:2026-11-24T10:00:00Z"
eq "R5: 1 commits/<head> call" "$(prs_gh "/commits/$B")" 1
eq "R5: 1 PUT" "$(prs_puts)" $((P0 + 1))
eq "R5: the PUT carries {sha, at}" "$(jq -c '.fields' "$PRS/put-$((P0 + 1)).json")" "{\"head_commit\":{\"sha\":\"$B\",\"at\":\"2026-11-24T10:00:00Z\"}}"
grep -q "head-commit $R#5 reason=sha gh_rc=0 put=ok" "$LOG" && ok "R5: one log line" || bad "R5: log: $(tail -1 "$LOG")"
run pr_record_head_commit_time "$R" 5 "$B"
eq "R5: the second call is a hit" "$(rc):$(out):$(prs_gh "/commits/$B")" "0:2026-11-24T10:00:00Z:1"
# The worker suite's RT posts this body to the real route.
FX="$REPO/worker/jobs/test/fixtures/pr-record-files.bh-9935.json"
jq -nc '{sha:"x", commit:{committer:{date:"2026-11-24T10:00:00.000Z"}}}' > "$PRS/gh/commit-$A.json"
P0=$(prs_puts)
run pr_record_head_commit_time o/bh9935-rt 7 "$A"
eq "R5: the fraction is dropped" "$(out)" 2026-11-24T10:00:00Z
eq "R5: the PUT body is the worker fixture's head_commit_put" \
  "$(jq -S . "$PRS/put-$((P0 + 1)).json")" "$(jq -S '.head_commit_put' "$FX")"
P0=$(prs_puts)
run pr_record_head_commit_time "$R" 6 "$(printf 'c%.0s' $(seq 40))"
eq "R5b: a 404 is rc 44, nothing printed" "$(rc):$(out)" "44:"
touch "$PRS/gh-fail"
run pr_record_head_commit_time "$R" 6 "$B"
eq "R5b: GitHub fails: rc 75, nothing printed" "$(rc):$(out)" "75:"
eq "R5b: no PUT" "$(prs_puts)" "$P0"
grep -q "head-commit $R#6 reason=unknown gh_rc=75 put=skipped" "$LOG" && ok "R5b: gh_rc=75 logged" || bad "R5b: log: $(tail -1 "$LOG")"
rm -f "$PRS/gh-fail"

# ---- R6: mergify -------------------------------------------------------------------
prs_set "$R" 7 "$(jq -nc --arg a "$A" '{repo:"o/bh9935-readers", number:7, head_sha:$a,
  mergify_queue:{state:"dequeued", code:"CHECKS_FAILED", draft_pr:8165, failing_checks:["lint"], left_sha:$a, comment_id:9, at:"2026-11-24T10:00:00Z"}}')"
run pr_record_mergify "$R" 7
eq "R6: rc 0, the object" "$(rc):$(out | jq -r '"\(.code) \(.draft_pr) \(.failing_checks | join(",")) \(.comment_id)"')" "0:CHECKS_FAILED 8165 lint 9"
prs_set "$R" 8 '{"repo":"o/bh9935-readers","number":8,"mergify_queue":null}'
run pr_record_mergify "$R" 8
eq "R6: NULL is rc 1" "$(rc):$(out)" "1:"
grep -q "mergify $R#8 miss=none" "$LOG" && ok "R6: miss=none logged" || bad "R6: log: $(tail -1 "$LOG")"

# ---- R7: unreadable ------------------------------------------------------------------
touch "$PRS/jobs-fail"
N0=$(wc -l < "$PRS/gh.log")
run pr_record_statuses "$R" 1
eq "R7: statuses unreadable is rc 1" "$(rc)" 1
run pr_record_mergify "$R" 7
eq "R7: mergify unreadable is rc 1" "$(rc)" 1
grep -q "statuses $R#1 miss=unreadable" "$LOG" && grep -q "mergify $R#7 miss=unreadable" "$LOG" \
  && ok "R7: miss=unreadable logged" || bad "R7: log: $(tail -2 "$LOG")"
eq "R7: 0 GitHub calls" "$(wc -l < "$PRS/gh.log")" "$N0"
rm -f "$PRS/jobs-fail"

# ---- R8: bad args --------------------------------------------------------------------
J0=$(wc -l < "$PRS/jobs.log")
run pr_record_statuses "$R" x;                 eq "R8: statuses bad number" "$(rc)" 2
run pr_record_statuses "$R" 1 abc1234;         eq "R8: statuses short head" "$(rc)" 2
run pr_record_mergify bad 1;                   eq "R8: mergify bad repo" "$(rc)" 2
run pr_record_head_commit_time "$R" 1;         eq "R8: head commit time needs a head" "$(rc)" 2
run pr_record_head_commit_time "$R" 1 "${A:0:7}"; eq "R8: head commit time short head" "$(rc)" 2
eq "R8: no request" "$(wc -l < "$PRS/jobs.log")" "$J0"

# ---- B1 ------------------------------------------------------------------------------
eq "B1: 0 calls to a real host" "$(wc -l < "$T/real-host.log" | tr -d ' ')" 0

echo "pr-record-readers.bh-9935: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

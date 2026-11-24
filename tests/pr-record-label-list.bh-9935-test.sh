#!/bin/bash
# tests/pr-record-label-list.bh-9935-test.sh — BH-9935 (BH-9926.3):
# pr_record_label_list in bin/lib/pr-record.sh answers "the PRs with label X"
# from the labels the record stores. It runs pr_record_list (one jobs GET,
# need=labels) and keeps the rows that carry the exact label. The REAL lib
# runs against the _jobs_req double of tests/lib/pr-record-store.bh-9935.sh,
# which answers the list GET with $PRS/list.json. curl and gh are PATH shims
# that log and fail, so a real host is never called.
#
#   L1  a fresh sync, 5 open PRs, 2 with merge-queue: the same sorted numbers as
#       a fixture GitHub `issues?labels=merge-queue&state=open` list; 1 jobs GET, need=labels
#   L2  a stale sync: rc 1, `stale` on stdout, an empty out-file
#   L3  merge-queue matches neither merge-queue-paused nor Merge-Queue
#   L4  a row with labels null (the worker answers missing:labels): rc 1, `field:labels`
#   L5  state merged is passed to the GET; bad args: rc 2, no request
#   B1  0 calls to a real host
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-record-label-list.bh-9935-test.sh
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
unset JOBS_URL GH_TOKEN PR_RECORD_LIST_MAX_AGE_S
# shellcheck source=bin/lib/pr-record.sh
. "$H/bin/lib/pr-record.sh"
R=o/bh9935-labels
run() { "$@" > "$T/stdout" 2>/dev/null; echo $? > "$T/rc"; }

# The record's list answer (GET /api/pr-records?repo=&state=open&need=labels).
# list <age_s> [jq filter on the answer]
ROWS='[{number:21, labels:["merge-queue"]}, {number:22, labels:["merge-queue-paused"]},
       {number:23, labels:["bug","merge-queue"]}, {number:24, labels:[]}, {number:25, labels:["Merge-Queue"]}]'
list() {
  jq -nc --argjson a "$1" "{rows: ($ROWS | map(. + {title: \"t\", head_sha: (\"a\" * 40)})), truncated: false, missing: null, unknown: 0,
    sync: {synced_at: \"2026-11-24T11:55:00Z\", age_s: \$a, rows: 5}} | ${2:-.}" > "$PRS/list.json"
}
# The same open PRs as GitHub's `issues?labels=merge-queue&state=open` answers them.
jq -nc '[{number:23, pull_request:{url:"x"}, labels:[{name:"bug"},{name:"merge-queue"}]},
         {number:21, pull_request:{url:"x"}, labels:[{name:"merge-queue"}]}]' > "$T/gh-issues.json"

# ---- L1 ----------------------------------------------------------------------------
list 60
J0=$(wc -l < "$PRS/jobs.log")
run pr_record_label_list "$R" merge-queue "$T/out1"
eq "L1: rc 0, nothing on stdout" "$(cat "$T/rc"):$(cat "$T/stdout")" "0:"
eq "L1: the record list equals the GitHub list" "$(jq -c '[.[].number] | sort' "$T/out1")" "$(jq -c '[.[].number] | sort' "$T/gh-issues.json")"
eq "L1: rows keep their keys" "$(jq -r '.[0].title' "$T/out1")" t
eq "L1: one jobs GET" "$(( $(wc -l < "$PRS/jobs.log") - J0 ))" 1
grep -q "GET /api/pr-records?repo=$R&state=open&need=labels$" "$PRS/jobs.log" && ok "L1: the GET asks state open and need=labels" \
  || bad "L1: GET: $(tail -1 "$PRS/jobs.log")"
eq "L1: the sync stamp is kept beside the file" "$(cat "$T/out1.sync")" 2026-11-24T11:55:00Z

# ---- L2 ----------------------------------------------------------------------------
list 99999
echo stale-content > "$T/out2"
run pr_record_label_list "$R" merge-queue "$T/out2"
eq "L2: a stale sync is rc 1, stale" "$(cat "$T/rc"):$(cat "$T/stdout")" "1:stale"
eq "L2: an empty out-file" "$(wc -c < "$T/out2" | tr -d ' ')" 0

# ---- L3 ----------------------------------------------------------------------------
list 60
run pr_record_label_list "$R" merge-queue-paused "$T/out3"
eq "L3: merge-queue-paused is its own label" "$(jq -c '[.[].number]' "$T/out3")" "[22]"
run pr_record_label_list "$R" Merge-Queue "$T/out3"
eq "L3: case matters as stored" "$(jq -c '[.[].number]' "$T/out3")" "[25]"
run pr_record_label_list "$R" merge "$T/out3"
eq "L3: no prefix match; an empty list is still an answer" "$(cat "$T/rc"):$(jq -c '.' "$T/out3")" "0:[]"

# ---- L4 ----------------------------------------------------------------------------
list 60 '.missing = "labels" | .rows[3].labels = null'
run pr_record_label_list "$R" merge-queue "$T/out4"
eq "L4: a null labels row is field:labels" "$(cat "$T/rc"):$(cat "$T/stdout")" "1:field:labels"
eq "L4: an empty out-file" "$(wc -c < "$T/out4" | tr -d ' ')" 0

# ---- L5 ----------------------------------------------------------------------------
list 60
run pr_record_label_list "$R" merge-queue "$T/out5" merged
grep -q "GET /api/pr-records?repo=$R&state=merged&need=labels$" "$PRS/jobs.log" && ok "L5: state merged is asked" \
  || bad "L5: GET: $(tail -1 "$PRS/jobs.log")"
J0=$(wc -l < "$PRS/jobs.log")
run pr_record_label_list "$R" "" "$T/out5";               eq "L5: no label is rc 2" "$(cat "$T/rc")" 2
run pr_record_label_list "$R" merge-queue;                eq "L5: no out-file is rc 2" "$(cat "$T/rc")" 2
run pr_record_label_list "$R" merge-queue "$T/o" draft;   eq "L5: a bad state is rc 2" "$(cat "$T/rc")" 2
run pr_record_label_list bad merge-queue "$T/o";          eq "L5: a bad repo is rc 2" "$(cat "$T/rc")" 2
eq "L5: no request on bad args" "$(wc -l < "$PRS/jobs.log")" "$J0"

# ---- B1 ----------------------------------------------------------------------------
eq "B1: 0 calls to a real host" "$(wc -l < "$T/real-host.log" | tr -d ' ')" 0

echo "pr-record-label-list.bh-9935: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

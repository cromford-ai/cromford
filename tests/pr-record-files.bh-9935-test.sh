#!/bin/bash
# contract-test: RT pins the files PUT body against the worker suite fixture (worker/jobs/test/fixtures/pr-record-files.bh-9935.json); every other case asserts fields
# tests/pr-record-files.bh-9935-test.sh — BH-9935 (BH-9926.3): pr_record_files
# in bin/lib/pr-record.sh reads `pulls/<n>/files` one time for each head sha
# and keeps the list in the PR record. The REAL lib runs against the in-file
# record store and the gh_rest double of tests/lib/pr-record-store.bh-9935.sh.
# curl and gh are PATH shims that log and fail, so a real host is never called.
#
#   F1  two reads of head A: 1 pulls/7/files call, the same sorted file both times, 1 PUT
#   F2  then head B: 1 more call (2 in total), reason=sha, and the record holds sha B
#   F3  a record hit with age_s 99999: 0 calls (a head sha never changes)
#   F4  30 full pages (GitHub's 3,000 cap): printed, 0 PUT, the next call reads again
#   F5  gh_rest fails: rc 75, an empty out-file, 0 PUT, one `files … gh_rc=75` log line
#   F6  a 7-char head: rc 2, 0 calls; no out-file arg: rc 2
#   F7  the PUT fails: the list is printed, rc 0, the log says put=failed
#   F8  the jobs read fails: GitHub is read, the list is printed, no PUT (put=skipped)
#   F9  a 2,999-path list (a PUT body above 128 KB) is stored: 30 pages, put=ok
#   RT  the PUT body equals files_put of the worker suite fixture
#   B1  0 calls to a real host
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-record-files.bh-9935-test.sh
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
R=o/bh9935-files
# page <n> <page> <names...> — one GitHub pulls/<n>/files page.
page() { local n="$1" p="$2"; shift 2; jq -nc '$ARGS.positional | map({filename: ., status: "modified"})' --args "$@" > "$PRS/gh/files-$n-p$p.json"; }
files() { pr_record_files "$@" > "$T/stdout" 2>/dev/null; echo $? > "$T/rc"; }

# ---- F1/F2 ---------------------------------------------------------------------
page 7 1 zeta.sh "docs/a b.md" README.md zeta.sh
files "$R" 7 "$A" "$T/out1"
eq "F1: rc 0 on the first read" "$(cat "$T/rc")" 0
eq "F1: the list is sorted and unique" "$(cat "$T/out1")" "$(printf 'README.md\ndocs/a b.md\nzeta.sh')"
eq "F1: 1 GitHub call" "$(prs_gh /pulls/7/files)" 1
eq "F1: the call asks 100 per page" "$(grep -c 'per_page=100' "$PRS/gh.log")" 1
eq "F1: 1 PUT" "$(prs_puts)" 1
eq "F1: the record holds sha A" "$(prs_row "$R" 7 | jq -r '.files.sha')" "$A"
files "$R" 7 "$A" "$T/out2"
eq "F1: rc 0 on the second read" "$(cat "$T/rc")" 0
eq "F1: the second read makes no GitHub call" "$(prs_gh /pulls/7/files)" 1
eq "F1: the same file both times" "$(cat "$T/out2")" "$(cat "$T/out1")"
eq "F1: still 1 PUT" "$(prs_puts)" 1
page 7 1 new.sh
files "$R" 7 "$B" "$T/out3"
eq "F2: a new head makes 1 more call" "$(prs_gh /pulls/7/files)" 2
eq "F2: the record holds sha B" "$(prs_row "$R" 7 | jq -r '.files.sha')" "$B"
eq "F2: the new list" "$(cat "$T/out3")" new.sh
grep -q "files $R#7 reason=sha gh_rc=0 pages=1 put=ok" "$LOG" && ok "F2: one log line per GitHub read" || bad "F2: log: $(cat "$LOG")"
eq "F2: two log lines for two reads" "$(grep -c "^.* files $R#7 " "$LOG")" 2

# ---- F3 --------------------------------------------------------------------------
prs_set "$R" 8 "$(jq -nc --arg a "$A" '{repo:"o/bh9935-files", number:8, state:"open", files:{sha:$a, paths:["x.md"]}}')"
echo 99999 > "$PRS/age"
files "$R" 8 "$A" "$T/out4"
eq "F3: an old record still hits" "$(cat "$T/out4")" x.md
eq "F3: 0 calls" "$(prs_gh /pulls/8/files)" 0
echo 0 > "$PRS/age"
# The head given in capitals finds the lowercase sha.
files "$R" 8 "$(tr a-f A-F <<<"$A")" "$T/out4b"
eq "F3: a capital head is the same sha" "$(prs_gh /pulls/8/files)$(cat "$T/out4b")" "0x.md"

# ---- F4 --------------------------------------------------------------------------
for p in $(seq 1 30); do
  jq -nc --argjson p "$p" '[range(0;100) | {filename: "f\($p)-\(.)", status: "added"}]' > "$PRS/gh/files-9-p$p.json"
done
P0=$(prs_puts)
files "$R" 9 "$A" "$T/out5"
eq "F4: rc 0" "$(cat "$T/rc")" 0
eq "F4: 3,000 paths printed" "$(wc -l < "$T/out5" | tr -d ' ')" 3000
eq "F4: 30 page calls" "$(prs_gh /pulls/9/files)" 30
eq "F4: no PUT of a cut list" "$(prs_puts)" "$P0"
grep -q "files $R#9 reason=unknown gh_rc=0 pages=30 put=skipped-cut" "$LOG" && ok "F4: the log names the cut" || bad "F4: log: $(tail -1 "$LOG")"
files "$R" 9 "$A" "$T/out5"
eq "F4: the next call reads again" "$(prs_gh /pulls/9/files)" 60

# ---- F5 --------------------------------------------------------------------------
touch "$PRS/gh-fail"
echo stale > "$T/out6"
P0=$(prs_puts)
files "$R" 10 "$A" "$T/out6"
eq "F5: rc 75" "$(cat "$T/rc")" 75
eq "F5: the out-file is empty" "$(wc -c < "$T/out6" | tr -d ' ')" 0
eq "F5: 0 PUT" "$(prs_puts)" "$P0"
eq "F5: one log line" "$(grep -c "files $R#10 reason=unknown gh_rc=75" "$LOG")" 1
rm -f "$PRS/gh-fail"

# ---- F6 --------------------------------------------------------------------------
N0=$(wc -l < "$PRS/gh.log"); J0=$(wc -l < "$PRS/jobs.log")
files "$R" 11 "${A:0:7}" "$T/out7"
eq "F6: a 7-char head is rc 2" "$(cat "$T/rc")" 2
files "$R" 11 "$A"
eq "F6: no out-file is rc 2" "$(cat "$T/rc")" 2
files "$R" 0 "$A" "$T/out7"
eq "F6: number 0 is rc 2" "$(cat "$T/rc")" 2
eq "F6: 0 GitHub calls" "$(wc -l < "$PRS/gh.log")" "$N0"
eq "F6: 0 jobs calls" "$(wc -l < "$PRS/jobs.log")" "$J0"

# ---- F7 / F8 -----------------------------------------------------------------------
page 12 1 b.sh a.sh
touch "$PRS/put-fail"
files "$R" 12 "$A" "$T/out8"
eq "F7: a failed PUT still prints the list, rc 0" "$(cat "$T/rc"):$(tr '\n' ' ' < "$T/out8")" "0:a.sh b.sh "
grep -q "files $R#12 reason=unknown gh_rc=0 pages=1 put=failed" "$LOG" && ok "F7: put=failed" || bad "F7: log: $(tail -1 "$LOG")"
rm -f "$PRS/put-fail"
touch "$PRS/jobs-fail"
P0=$(prs_puts)
files "$R" 12 "$A" "$T/out9"
eq "F8: the jobs read fails: GitHub is read, rc 0" "$(cat "$T/rc"):$(tr '\n' ' ' < "$T/out9")" "0:a.sh b.sh "
eq "F8: no PUT attempt" "$(prs_puts)" "$P0"
grep -q "files $R#12 reason=unreadable gh_rc=0 pages=1 put=skipped" "$LOG" && ok "F8: put=skipped" || bad "F8: log: $(tail -1 "$LOG")"
rm -f "$PRS/jobs-fail"

# ---- F9 --------------------------------------------------------------------------
# 2,999 paths of about 75 bytes: a PUT body near 230 KB, above the 128 KB one
# argv string may hold, so the fields must reach jq on stdin.
for p in $(seq 1 30); do
  jq -nc --argjson p "$p" '[range(0; (if $p == 30 then 99 else 100 end)) | {filename: "worker/jobs/src/some/long/directory/name/for/the/test/p\($p)-file-\(.).js"}]' \
    > "$PRS/gh/files-13-p$p.json"
done
files "$R" 13 "$A" "$T/out11"
eq "F9: rc 0" "$(cat "$T/rc")" 0
grep -q "files $R#13 reason=unknown gh_rc=0 pages=30 put=ok" "$LOG" && ok "F9: a 2,999-path list is stored" || bad "F9: log: $(tail -1 "$LOG")"
eq "F9: the record holds 2,999 paths" "$(prs_row "$R" 13 | jq '.files.paths | length')" 2999
[ "$(wc -c < "$PRS/put-$(prs_puts).json")" -gt 131072 ] && ok "F9: the PUT body is above 128 KB" || bad "F9: the PUT body is small"

# ---- RT --------------------------------------------------------------------------
FX="$REPO/worker/jobs/test/fixtures/pr-record-files.bh-9935.json"
page 7 1 worker/jobs/src/routes/pr-records.js README.md "docs/a b.md" bin/lib/pr-record.sh README.md
P0=$(prs_puts)
files o/BH9935-RT 7 "$A" "$T/out10"
eq "RT: one PUT" "$(prs_puts)" $((P0 + 1))
eq "RT: the PUT body is the worker fixture's files_put" \
  "$(jq -S . "$PRS/put-$((P0 + 1)).json")" "$(jq -S '.files_put' "$FX")"

# ---- B1 --------------------------------------------------------------------------
eq "B1: 0 calls to a real host" "$(wc -l < "$T/real-host.log" | tr -d ' ')" 0

echo "pr-record-files.bh-9935: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

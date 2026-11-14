#!/bin/bash
# tests/human-block-report.bh-9427-test.sh — BH-9427 (C0): the human-block
# report and its daily line. Runs the real bin/human-block-report.sh, installed
# with its source closure into a scratch harness, over the hand-written
# conductor logs in tests/fixtures/bh-9427/ (the exact mc_transition line
# format, bin/lib/mc/settle.sh). Every run pins --now 2026-11-12T06:40:00Z.
#
# The hand count of the fixture (window 7d, start 2026-11-05 06:40:00Z):
#   14 episodes on 13 PRs. Out: #9001 (before the window), #9002 (1 minute
#   before the window, ended inside it), #9110 (after --now), the truncated
#   last line #9112 (it ends at BLOCKED_HUMAN), the "=>" arrow of #9113, the
#   no-timestamp and garbage lines.
#   prequeue-red 4/3 waits 10 40 50 60 (median 45, total 160) 2 merged 1 closed 1 open
#   queue-ejected-twice 3/3 waits 15 20 3280 (median 20, total 3315) 1/1/1/0
#   iron-law 2/2 waits 31 120 (median 75, total 151) 1 merged 1 closed
#   (none) 1 5 open; conflict-unresolvable 1 60 merged; hotfix-migration-hold 1 30 open;
#   iron-law-x 1 60 closed; stale-replan 1 1240 blocked.
#   TOTAL 14 13 median 45 total 5021 merged 5 closed 4 blocked 2 open 3.
#   Merged PRs in the window: 9002 9100 9103 9106 project-3#12 9108 = 6, of them 5
#   human-blocked before the merge (all but 9106): share 83.3.
#
# A fakebin first on PATH holds a `gh`, a `curl` and a `claude` that write a
# sentinel: B1 fails on any call (0 vendor calls). Every case copies the
# fixtures into its own directory, so no case depends on another and two runs
# of the suite in parallel pass.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/human-block-report.bh-9427-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SCRIPT_REL=bin/human-block-report.sh
FIX="$DIR/tests/fixtures/bh-9427"
NOW=2026-11-12T06:40:00Z
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$T/fakebin"
if [ -f "$DIR/$SCRIPT_REL" ]; then
  scratch_install_closure "$SCRIPT_REL" "$H" >/dev/null || { echo "FAIL: scratch_install_closure $SCRIPT_REL"; exit 1; }
else
  bad "$SCRIPT_REL missing"
fi
for v in gh curl claude; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/vendor-called"\nexit 1\n' "$v" "$T" > "$T/fakebin/$v"
  chmod +x "$T/fakebin/$v"
done
export PATH="$T/fakebin:$PATH"
unset HUMAN_BLOCK_REPORT_WINDOW_D HUMAN_BLOCK_REPORT_DETAILS

# case_dir <name> — a fresh dir with its own copy of both fixture logs.
case_dir() {
  local d="$T/case/$1"
  mkdir -p "$d"
  cp "$FIX/merge-conductor.1.log" "$d/merge-conductor.log.1"
  cp "$FIX/merge-conductor.log" "$d/"
  printf '%s' "$d"
}
# run <dir> [args...] — the script on that dir's logs; stdout to $d/out, rc to $d/rc.
run() {
  local d="$1"; shift
  HARNESS="$H" bash "$H/$SCRIPT_REL" --now "$NOW" --log "$d/merge-conductor.log.1" --log "$d/merge-conductor.log" "$@" > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
}
# row <file> <first-col> — the TSV row whose first column is that word.
row() { awk -F'\t' -v k="$2" '$1 == k { print; exit }' "$1"; }
col() { row "$1" "$2" | cut -f"$3"; }

# ── R1 parse ───────────────────────────────────────────────────────────────
d=$(case_dir r1); run "$d"
check "R1 rc 0" '[ "$(cat "$d/rc")" = 0 ]'
check "R1 TOTAL blocks = 14 (non-transition lines add none)" '[ "$(col "$d/out" TOTAL 2)" = 14 ]'
check "R1 TOTAL prs = 13" '[ "$(col "$d/out" TOTAL 3)" = 13 ]'
check "R1 the MERGED-by-conductor line adds no merge (merged_prs 6)" '[ "$(col "$d/out" merged_prs 2)" = 6 ]'
check "R1 the reason holding -> is a prequeue-red episode" 'grep -qP "^detail\tprequeue-red\ta -> b\t1$" "$d/out"'
check "R1 the truncated last line is no episode (stale-replan 1, not 2)" '[ "$(col "$d/out" stale-replan 2)" = 1 ]'
check "R1 no BLOCKED_AGENT or STACK_PARENT_MERGED class" '! grep -qE "^(BLOCKED_AGENT|STACK_PARENT_MERGED|re-reasoned)" "$d/out"'

# ── R2 classes ─────────────────────────────────────────────────────────────
classes=$(awk -F'\t' 'p && $1 == "TOTAL" { exit } p { print $1 } $1 == "class" { p = 1 }' "$d/out" | tr '\n' ' ')
check "R2 class rows in order (got: $classes)" '[ "$classes" = "prequeue-red queue-ejected-twice iron-law (none) conflict-unresolvable hotfix-migration-hold iron-law-x stale-replan " ]'
check "R2 prequeue-red blocks 4 prs 3 (a PR blocked twice is 1 PR)" '[ "$(col "$d/out" prequeue-red 2)/$(col "$d/out" prequeue-red 3)" = 4/3 ]'
check "R2 queue-ejected-twice blocks 3 prs 3" '[ "$(col "$d/out" queue-ejected-twice 2)/$(col "$d/out" queue-ejected-twice 3)" = 3/3 ]'
check "R2 iron-law (1 hit) and (2 hits) are one class" '[ "$(col "$d/out" iron-law 2)" = 2 ]'
check "R2 iron-law-x is its own class" '[ "$(col "$d/out" iron-law-x 2)" = 1 ]'
check "R2 empty reason -> (none)" '[ "$(col "$d/out" "(none)" 2)" = 1 ]'
check "R2 detail tests/lanes-registry-test.sh under prequeue-red, first" '[ "$(grep -P "^detail\tprequeue-red\t" "$d/out" | head -1)" = "$(printf "detail\tprequeue-red\ttests/lanes-registry-test.sh\t2")" ]'
check "R2 detail unknown-reason under queue-ejected-twice" 'grep -qP "^detail\tqueue-ejected-twice\tunknown, no Mergify dequeue reason\t2$" "$d/out"'
check "R2 detail - for the bare queue-ejected-twice" 'grep -qP "^detail\tqueue-ejected-twice\t-\t1$" "$d/out"'
check "R2 detail of conflict-unresolvable is the file" 'grep -qP "^detail\tconflict-unresolvable\tcatalog/state-paths.json\t1$" "$d/out"'
check "R2 detail of hotfix-migration-hold" 'grep -qP "^detail\thotfix-migration-hold\tthe stage held x\t1$" "$d/out"'

# ── R3 outcomes (columns 6..9 = merged closed blocked open) ────────────────
oc() { row "$d/out" "$1" | cut -f6-9 | tr '\t' ' '; }
check "R3 prequeue-red 2 merged 1 closed 1 open (got $(oc prequeue-red))" '[ "$(oc prequeue-red)" = "2 1 0 1" ]'
check "R3 queue-ejected-twice merged/closed/blocked (got $(oc queue-ejected-twice))" '[ "$(oc queue-ejected-twice)" = "1 1 1 0" ]'
check "R3 iron-law: block in .log.1, MERGED in .log -> merged; CLOSED -> closed" '[ "$(oc iron-law)" = "1 1 0 0" ]'
check "R3 ABANDONED -> closed" '[ "$(oc iron-law-x)" = "0 1 0 0" ]'
check "R3 still blocked -> blocked" '[ "$(oc stale-replan)" = "0 0 1 0" ]'
check "R3 left the block, nothing after -> open" '[ "$(oc "(none)")" = "0 0 0 1" ]'
check "R3 BLOCKED_HUMAN -> MERGED directly -> merged" '[ "$(oc conflict-unresolvable)" = "1 0 0 0" ]'
check "R3 TOTAL outcomes (got $(oc TOTAL))" '[ "$(oc TOTAL)" = "5 4 2 3" ]'

# ── R4 waits (col 4 median, col 5 total) ───────────────────────────────────
check "R4 even-count median floor((40+50)/2)=45, total 160" '[ "$(col "$d/out" prequeue-red 4)/$(col "$d/out" prequeue-red 5)" = 45/160 ]'
check "R4 even-count median floor((31+120)/2)=75, total 151" '[ "$(col "$d/out" iron-law 4)/$(col "$d/out" iron-law 5)" = 75/151 ]'
check "R4 odd-count median 20; still-blocked wait runs to --now (3280)" '[ "$(col "$d/out" queue-ejected-twice 4)/$(col "$d/out" queue-ejected-twice 5)" = 20/3315 ]'
check "R4 stale-replan still blocked: 1240 minutes to --now" '[ "$(col "$d/out" stale-replan 5)" = 1240 ]'
check "R4 TOTAL median 45 total 5021" '[ "$(col "$d/out" TOTAL 4)/$(col "$d/out" TOTAL 5)" = 45/5021 ]'
check "R4 share row 6 merged, 5 blocked before merge, 83.3" '[ "$(row "$d/out" merged_prs)" = "$(printf "merged_prs\t6\thuman_blocked_before_merge\t5\tshare_pct\t83.3")" ]'

# ── R5 window ──────────────────────────────────────────────────────────────
check "R5 1 minute inside counts, 1 minute before does not (no head-not-reapproved row)" '! grep -qP "^head-not-reapproved\t" "$d/out"'
check "R5 a block that started before the window does not count (iron-law 2, not 3)" '[ "$(col "$d/out" iron-law 2)" = 2 ]'
d=$(case_dir r5); run "$d" --last 1d
check "R5 --last 1d rc 0" '[ "$(cat "$d/rc")" = 0 ]'
check "R5 --last 1d keeps 3 episodes (got $(col "$d/out" TOTAL 2))" '[ "$(col "$d/out" TOTAL 2)" = 3 ]'
check "R5 --last 1d header says 1d" 'head -1 "$d/out" | grep -q "window 1d ending 2026-11-12T06:40:00Z"'
check "R5 --last 1d merged_prs 1 (#9108)" '[ "$(col "$d/out" merged_prs 2)" = 1 ]'

# ── R6 arguments ───────────────────────────────────────────────────────────
for a in "--last 0d" "--last 91d" "--last x" "--last 7" "--bogus" "--repo nope" "--now yesterday"; do
  d=$(case_dir "r6-${a// /_}")
  # shellcheck disable=SC2086
  run "$d" $a --daily
  check "R6 '$a' -> rc 2" '[ "$(cat "$d/rc")" = 2 ]'
  check "R6 '$a' writes no human-block.log" '[ ! -e "$H/logs/human-block.log" ]'
done

# ── R7 repo ────────────────────────────────────────────────────────────────
d=$(case_dir r7); run "$d" --repo example-org/cromford
check "R7 --repo rc 0" '[ "$(cat "$d/rc")" = 0 ]'
check "R7 --repo cromford TOTAL 11 blocks (got $(col "$d/out" TOTAL 2))" '[ "$(col "$d/out" TOTAL 2)" = 11 ]'
check "R7 --repo share 5 merged, 4 blocked, 80.0" '[ "$(row "$d/out" merged_prs | cut -f2,4,6 | tr "\t" " ")" = "5 4 80.0" ]'
check "R7 --repo repo row median 60" '[ "$(row "$d/out" repo)" = "$(printf "repo\texample-org/cromford\tblocks\t11\tmerged\t5\tblocked_merged\t4\tshare_pct\t80.0\tmedian_wait_min\t60")" ]'
check "R7 --repo prints no project-3 row" '! grep -q "example-org/project-3" "$d/out"'
d=$(case_dir r7b); run "$d"
check "R7 all repos: project-3 row" '[ "$(grep -P "^repo\texample-org/project-3\t" "$d/out")" = "$(printf "repo\texample-org/project-3\tblocks\t3\tmerged\t1\tblocked_merged\t1\tshare_pct\t100.0\tmedian_wait_min\t20")" ]'
d=$(case_dir r7c); run "$d" --repo example-org/nothing
check "R7 no match rc 0" '[ "$(cat "$d/rc")" = 0 ]'
check "R7 no match TOTAL zeros" '[ "$(row "$d/out" TOTAL | cut -f2-9 | tr "\t" " ")" = "0 0 0 0 0 0 0 0" ]'

# ── R8 zero merges ─────────────────────────────────────────────────────────
check "R8 no match: share n/a" '[ "$(col "$d/out" merged_prs 6)" = n/a ]'
d=$(case_dir r8)
HARNESS="$H" bash "$H/$SCRIPT_REL" --now 2026-11-05T07:00:00Z --last 1d --log "$d/merge-conductor.log.1" --log "$d/merge-conductor.log" > "$d/out" 2>&1; echo $? > "$d/rc"
check "R8 blocks but no merge: rc 0" '[ "$(cat "$d/rc")" = 0 ]'
check "R8 blocks but no merge (#9001, #9002, #9100; the MERGED of #9002 is after --now): 3 blocks, share n/a" '[ "$(col "$d/out" TOTAL 2)/$(col "$d/out" merged_prs 6)" = 3/n/a ]'

# ── R9 default files ───────────────────────────────────────────────────────
H9="$T/h9"; mkdir -p "$H9/logs"
scratch_install_closure "$SCRIPT_REL" "$H9" >/dev/null 2>&1
cp "$FIX/merge-conductor.1.log" "$H9/logs/merge-conductor.log.1"
cp "$FIX/merge-conductor.log" "$H9/logs/"
HARNESS="$H9" bash "$H9/$SCRIPT_REL" --now "$NOW" > "$T/r9.out" 2>&1; r9=$?
check "R9 default files rc 0" '[ "$r9" = 0 ]'
check "R9 default files: TOTAL 14" '[ "$(col "$T/r9.out" TOTAL 2)" = 14 ]'
check "R9 default files: .log.1 then .log in the header" 'head -1 "$T/r9.out" | grep -qF "source $H9/logs/merge-conductor.log.1 $H9/logs/merge-conductor.log"'
rm "$H9/logs/merge-conductor.log.1"
HARNESS="$H9" bash "$H9/$SCRIPT_REL" --now "$NOW" > "$T/r9b.out" 2>&1; r9=$?
check "R9 no rotated part: reads .log alone (rc 0, MERGED of #9100 has no block: 11 episodes)" '[ "$r9/$(col "$T/r9b.out" TOTAL 2)" = 0/11 ]'

# ── D1-D3 the daily line ───────────────────────────────────────────────────
HD="$T/hd"; mkdir -p "$HD/logs"
scratch_install_closure "$SCRIPT_REL" "$HD" >/dev/null 2>&1
d=$(case_dir d1)
for i in 1 2; do
  HARNESS="$HD" bash "$HD/$SCRIPT_REL" --now "$NOW" --log "$d/merge-conductor.log.1" --log "$d/merge-conductor.log" --daily > "$d/out$i" 2>&1
  echo $? > "$d/rc$i"
done
check "D1 --daily rc 0 twice" '[ "$(cat "$d/rc1")$(cat "$d/rc2")" = 00 ]'
check "D1 two runs -> two [human-block] status=ok lines" '[ "$(grep -c "\[human-block\] status=ok " "$HD/logs/human-block.log")" = 2 ]'
check "D1 nothing else in the file" '[ "$(wc -l < "$HD/logs/human-block.log")" = 2 ]'
line=$(tail -1 "$HD/logs/human-block.log")
kv() { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
o="$d/out2"
check "D2 line starts with the ISO now" '[ "${line%% *}" = "$NOW" ]'
check "D2 window=7d" '[ "$(kv window)" = 7d ]'
check "D2 blocks" '[ "$(kv blocks)" = "$(col "$o" TOTAL 2)" ]'
check "D2 prs" '[ "$(kv prs)" = "$(col "$o" TOTAL 3)" ]'
check "D2 median_wait_min" '[ "$(kv median_wait_min)" = "$(col "$o" TOTAL 4)" ]'
check "D2 total_wait_min" '[ "$(kv total_wait_min)" = "$(col "$o" TOTAL 5)" ]'
check "D2 merged" '[ "$(kv merged)" = "$(col "$o" TOTAL 6)" ]'
check "D2 closed" '[ "$(kv closed)" = "$(col "$o" TOTAL 7)" ]'
check "D2 still_blocked" '[ "$(kv still_blocked)" = "$(col "$o" TOTAL 8)" ]'
check "D2 open" '[ "$(kv open)" = "$(col "$o" TOTAL 9)" ]'
check "D2 merged_prs" '[ "$(kv merged_prs)" = "$(col "$o" merged_prs 2)" ]'
check "D2 blocked_share_pct" '[ "$(kv blocked_share_pct)" = "$(col "$o" merged_prs 6)" ]'
want_classes=$(awk -F'\t' 'p && $1 == "TOTAL" { exit } p { printf "%s%s:%s/%s", s, $1, $2, $4; s = "," } $1 == "class" { p = 1 }' "$o")
check "D2 classes= equals the class rows" '[ "$(kv classes)" = "$want_classes" ]'
want_repos=$(awk -F'\t' '$1 == "repo" { printf "%s%s:%s/%s/%s/%s", s, $2, $4, $8, $6, $12; s = "," }' "$o")
check "D2 repos= equals the repo rows" '[ "$(kv repos)" = "$want_repos" ]'
check "D2 the numbers are the hand count" '[ "$(kv blocks)/$(kv median_wait_min)/$(kv blocked_share_pct)" = 14/45/83.3 ]'

HN="$T/hn"; mkdir -p "$HN/logs"
scratch_install_closure "$SCRIPT_REL" "$HN" >/dev/null 2>&1
HARNESS="$HN" bash "$HN/$SCRIPT_REL" --now "$NOW" --daily > "$T/d3.out" 2>&1; d3=$?
check "D3 no log: rc 3" '[ "$d3" = 3 ]'
check "D3 no log: stdout names the paths" 'grep -qF "human-block-report: no conductor log at $HN/logs/merge-conductor.log.1 $HN/logs/merge-conductor.log" "$T/d3.out"'
check "D3 no log: one status=no-source line naming the paths" '[ "$(grep -c "\[human-block\] status=no-source paths=$HN/logs/merge-conductor.log.1,$HN/logs/merge-conductor.log" "$HN/logs/human-block.log")" = 1 ]'
check "D3 no log: no status=ok line" '! grep -q "status=ok" "$HN/logs/human-block.log"'

# ── K1 knobs ───────────────────────────────────────────────────────────────
d=$(case_dir k1a); HUMAN_BLOCK_REPORT_WINDOW_D=1 run "$d"
check "K1 HUMAN_BLOCK_REPORT_WINDOW_D=1 narrows the default window (3 blocks)" '[ "$(col "$d/out" TOTAL 2)" = 3 ]'
d=$(case_dir k1b); HUMAN_BLOCK_REPORT_WINDOW_D=1 run "$d" --last 7d
check "K1 --last wins over the knob" '[ "$(col "$d/out" TOTAL 2)" = 14 ]'
d=$(case_dir k1c); HUMAN_BLOCK_REPORT_WINDOW_D=abc run "$d"
check "K1 =abc falls back to 7 (14 blocks)" '[ "$(col "$d/out" TOTAL 2)" = 14 ]'
check "K1 =abc names window_src fallback" 'head -1 "$d/out" | grep -q "window_src fallback"'
HKF="$T/hkf"; mkdir -p "$HKF/logs"; scratch_install_closure "$SCRIPT_REL" "$HKF" >/dev/null 2>&1
HUMAN_BLOCK_REPORT_WINDOW_D=abc HARNESS="$HKF" bash "$HKF/$SCRIPT_REL" --now "$NOW" --log "$d/merge-conductor.log" --daily >/dev/null 2>&1
check "K1 =abc names window_src=fallback on the daily line" 'grep -q "window_src=fallback" "$HKF/logs/human-block.log"'
d=$(case_dir k1d); HUMAN_BLOCK_REPORT_DETAILS=1 run "$d"
check "K1 HUMAN_BLOCK_REPORT_DETAILS=1: one detail row for prequeue-red" '[ "$(grep -cP "^detail\tprequeue-red\t" "$d/out")" = 1 ]'
check "K1 default DETAILS 3: three detail rows for prequeue-red" '[ "$(grep -cP "^detail\tprequeue-red\t" "$T/case/r1/out")" = 3 ]'

# ── B1 vendor budget ───────────────────────────────────────────────────────
check "B1 0 calls to gh, curl or claude ($(cat "$T/vendor-called" 2>/dev/null | head -3))" '[ ! -e "$T/vendor-called" ]'

echo "human-block-report.bh-9427: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

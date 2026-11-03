#!/bin/bash
# tests/e2e-main-baseline.bh-7941-test.sh — BH-7941: bin/lib/e2e-main-baseline.sh
# emb_section, the lead review's `## Main E2E` section. It reads main's latest
# completed E2E-class run (push or schedule) and the head's, through gh_rest,
# and prints which failing Playwright specs are red on main too (pre-existing)
# and which are red on the head only (regression).
#
# A stub `gh` is first on PATH: it answers from fixture files in this test's
# scratch dir, logs every call, and exits 1 with no output on any path it does
# not know (a throw on an unimplemented method). 0 network calls.
#
#   B1  main failed with A, B; head failed with B, C -> pre-existing B,
#       regression C, EMB_STATE=yes
#   B2  B at :12:5 on main and :14:5 on the head -> pre-existing (the id has no
#       line:col)
#   B3  main success, head failure A -> regression A, no pre-existing id
#   B4  main failed, its log has no spec line -> `unknown: main run <id> failed
#       and no spec ids were read`, no comparison
#   B5  only "CI" and "Bridge npm smoke test" on main -> none, 1 gh call
#   B6  the main list answers 403 rate limit -> COULD NOT READ, unknown
#   B7  REVIEW_LEVEL_E2E_RATCHET=0 -> off, 0 gh calls
#   B8  5 failed jobs in each run -> at most 6 gh calls; the section says how
#       many failed jobs were read
#   B9  the head has no completed E2E-class run -> says so, no regression list
#   B10 the head's only E2E run was cancelled -> the same as B9
#   B11 35 failing specs on main -> 30 kept, the run line and a note say so
#   B12 REVIEW_LEVEL_E2E_BASELINE_CALLS=2 (row review.e2e_baseline_calls) -> at
#       most 2 gh calls; the head side says the call budget was spent
#   B13 REVIEW_LEVEL_E2E_BASELINE_RUNS=20 -> both lists ask per_page=20 and the
#       none line names 20; a bad value (500) falls back to 50
#   B14 REVIEW_LEVEL_E2E_BASELINE_IDS=3 -> 3 ids kept;
#       REVIEW_LEVEL_E2E_BASELINE_JOBS=4 -> 4 of 5 failed jobs read
#   B15 emb_prompt_file writes the section to <out> and logs one
#       `<key>: main e2e <state>` line through the caller's log
#   M1  mutation: drop the :line:col strip -> B2 goes red
# Run: HARNESS_TEST_SANDBOX=1 bash tests/e2e-main-baseline.bh-7941-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$SRC/bin/lib/e2e-main-baseline.sh" ] || { echo "FAIL: bin/lib/e2e-main-baseline.sh does not exist"; exit 1; }

HB="$T/h"; mkdir -p "$HB/catalog" "$T/fakebin" "$T/fx" "$T/tmp"
scratch_install_closure bin/lib/e2e-main-baseline.sh "$HB" >/dev/null || bad "closure of bin/lib/e2e-main-baseline.sh"
cp "$SRC"/catalog/review-*.tsv "$HB/catalog/"
for f in bin/lib/e2e-paths.sh bin/lib/gh-rest.sh bin/lib/review-level.sh; do
  [ -f "$HB/$f" ] && ok || bad "the closure does not carry $f"
done

# The stub: `gh api -i -X GET <path>`. The fixture for <path> is fx/<key>,
# key = the path with every non-alnum byte as _. fx/<key>.status overrides 200.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
p=""; prev=""
for a in "\$@"; do [ "\$prev" = GET ] && p="\$a"; prev="\$a"; done
echo "\$p" >> "$T/calls"
k=\$(printf '%s' "\$p" | tr -c 'A-Za-z0-9' '_')
[ -f "$T/fx/\$k" ] || exit 1
st=200; [ -f "$T/fx/\$k.status" ] && st=\$(cat "$T/fx/\$k.status")
printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n' "\$st"
cat "$T/fx/\$k"
[ "\$st" = 200 ] || exit 1
exit 0
EOF
chmod +x "$T/fakebin/gh"

REPO=example-org/project-6
HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MAINSHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
fx() { cat > "$T/fx/$(key "$1")"; }
MAINLIST="repos/$REPO/actions/runs?branch=main&status=completed&per_page=50"
HEADLIST="repos/$REPO/actions/runs?head_sha=$HEAD&status=completed&per_page=50"

# run <name> <id> <event> <sha> <conclusion>
run() { jq -nc --arg n "$1" --argjson i "$2" --arg e "$3" --arg s "$4" --arg c "$5" \
  '{id:$i,name:$n,event:$e,head_sha:$s,conclusion:$c,created_at:"2026-10-21T03:00:00Z",path:(".github/workflows/"+($n|ascii_downcase|gsub(" ";"-"))+".yml")}'; }
runs() { jq -sc '{total_count:length,workflow_runs:.}'; }
# jobs <run-id> <failed-count> <first-job-id>
jobs() { local i out="" n="$2" j="$3"
  for ((i=0;i<n;i++)); do out="$out$(jq -nc --argjson i "$((j+i))" '{id:$i,name:("e2e shard "+($i|tostring)),conclusion:"failure"}')"; done
  out="$out$(jq -nc --argjson i "$((j+50))" '{id:$i,name:"e2e report",conclusion:"success"}')"
  printf '%s' "$out" | jq -sc '{total_count:length,jobs:.}' | fx "repos/$REPO/actions/runs/$1/jobs"; }
# log <job-id> <spec-line>... — a GitHub job log in the Playwright list-reporter shape
log() { local j="$1" i=1; shift
  { printf '2026-10-21T03:01:00.0000000Z Running 40 tests using 2 workers\n'
    for l in "$@"; do printf '2026-10-21T03:02:00.0000000Z   %d) [chromium] › %s ────────────────────\n' "$i" "$l"; i=$((i+1))
      printf '2026-10-21T03:02:00.0000000Z \n2026-10-21T03:02:00.0000000Z     Error: expect(locator).toBeVisible() failed\n'; done
    printf '2026-10-21T03:03:00.0000000Z   %d failed\n' "$#"; } | fx "repos/$REPO/actions/jobs/$j/logs"; }

A='e2e/a.spec.ts:10:5 › Area A › opens'
B12='e2e/checkout.spec.ts:12:5 › Checkout › pays'
B14='e2e/checkout.spec.ts:14:5 › Checkout › pays'
C='e2e/settings.spec.ts:30:3 › Settings › saves'

reset() { rm -f "$T"/fx/* "$T/calls"; unset REVIEW_LEVEL_E2E_RATCHET; }
# section [project] — runs emb_section in a fresh shell; OUT, ST, RC, CALLS
section() {
  OUT=$(cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" JOBS_URL= GH_ETAG=0 TMPDIR="$T/tmp" bash -c \
    '. "$HARNESS/bin/lib/e2e-main-baseline.sh" || exit 9; emb_section "$1" "$2" "$3"; rc=$?; echo "EMB_STATE=$EMB_STATE"; exit $rc' _ \
    "$REPO" "$HEAD" "${1:-project-6}" 2>"$T/err"); RC=$?
  ST=$(sed -n 's/^EMB_STATE=//p' <<<"$OUT")
  CALLS=$( [ -f "$T/calls" ] && wc -l < "$T/calls" | tr -d ' ' || echo 0)
}
under() { awk -v h="$1" 'index($0,h)==1{f=1;next} /^[a-z]/{f=0} f' <<<"$OUT"; }

# ── B1 ──
reset
{ run CI 4400 push "$MAINSHA" success; run "E2E Tests" 4411 schedule "$MAINSHA" failure; } | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" failure | runs | fx "$HEADLIST"
jobs 4411 1 9001; jobs 5001 1 9101
log 9001 "$A" "$B12"; log 9101 "$B12" "$C"
section
[ "$RC" = 0 ] && ok || bad "B1 rc=$RC err=$(cat "$T/err")"
[ "$ST" = yes ] && ok || bad "B1 state=$ST out=$OUT"
grep -q '^main: E2E Tests run 4411 (schedule, aaaaaaaa, 2026-10-21T03:00:00Z) failure; 2 failing spec(s)' <<<"$OUT" && ok || bad "B1 main line: $OUT"
grep -q '^head: E2E Tests run 5001 (pull_request, bbbbbbbb, 2026-10-21T03:00:00Z) failure; 2 failing spec(s)' <<<"$OUT" && ok || bad "B1 head line: $OUT"
pre=$(under 'pre-existing'); reg=$(under 'regression')
grep -qxF '  - e2e/checkout.spec.ts › Checkout › pays' <<<"$pre" && ok || bad "B1 pre-existing: $pre"
grep -q 'settings' <<<"$pre" && bad "B1 C listed as pre-existing" || ok
grep -qxF '  - e2e/settings.spec.ts › Settings › saves' <<<"$reg" && ok || bad "B1 regression: $reg"
grep -q 'checkout' <<<"$reg" && bad "B1 B listed as regression" || ok
grep -q 'a.spec' <<<"$pre$reg" && bad "B1 main-only A listed" || ok
[ "$CALLS" = 6 ] && ok || bad "B1 calls=$CALLS"

# ── B2 moved line ──
reset
run "E2E Tests" 4411 push "$MAINSHA" failure | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" failure | runs | fx "$HEADLIST"
jobs 4411 1 9001; jobs 5001 1 9101; log 9001 "$B12"; log 9101 "$B14"
section
grep -qxF '  - e2e/checkout.spec.ts › Checkout › pays' <<<"$(under 'pre-existing')" && ok || bad "B2 not pre-existing: $OUT"
grep -q '^  - ' <<<"$(under 'regression')" && bad "B2 a regression listed: $OUT" || ok

# ── B3 main green ──
reset
run "E2E Tests" 4411 push "$MAINSHA" success | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" failure | runs | fx "$HEADLIST"
jobs 5001 1 9101; log 9101 "$A"
section
grep -qxF '  - e2e/a.spec.ts › Area A › opens' <<<"$(under 'regression')" && ok || bad "B3 regression: $OUT"
grep -q '^  - ' <<<"$(under 'pre-existing')" && bad "B3 pre-existing listed: $OUT" || ok
[ "$ST" = yes ] && ok || bad "B3 state=$ST"
[ "$CALLS" = 4 ] && ok || bad "B3 calls=$CALLS (a green main run needs no jobs read)"

# ── B4 unparsable main log ──
reset
run "E2E Tests" 4411 push "$MAINSHA" failure | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" failure | runs | fx "$HEADLIST"
jobs 4411 1 9001; jobs 5001 1 9101
printf '2026-10-21T03:01:00.0000000Z Error: browserType.launch: Executable does not exist\n' | fx "repos/$REPO/actions/jobs/9001/logs"
log 9101 "$A"
section
grep -qx 'unknown: main run 4411 failed and no spec ids were read' <<<"$OUT" && ok || bad "B4 unknown line: $OUT"
grep -q '^  - ' <<<"$(under 'pre-existing')" && bad "B4 pre-existing listed: $OUT" || ok
grep -q '^regression' <<<"$OUT" && bad "B4 a regression list with no main ids: $OUT" || ok
[ "$ST" = unknown ] && ok || bad "B4 state=$ST"

# ── B5 no E2E-class run on main ──
reset
{ run CI 4400 push "$MAINSHA" success; run "Bridge npm smoke test" 4401 push "$MAINSHA" failure; run "Deploy Worker to Railway" 4402 push "$MAINSHA" success; } | runs | fx "$MAINLIST"
section
grep -qx 'none: no E2E-class workflow run on main in the last 50 completed runs' <<<"$OUT" && ok || bad "B5: $OUT"
[ "$ST" = none ] && ok || bad "B5 state=$ST"
[ "$CALLS" = 1 ] && ok || bad "B5 calls=$CALLS"

# ── B6 rate limited ──
reset
printf '{"message":"API rate limit exceeded"}' | fx "$MAINLIST"; echo 403 > "$T/fx/$(key "$MAINLIST").status"
section
[ "$RC" = 0 ] && ok || bad "B6 rc=$RC"
grep -q '^main: COULD NOT READ (' <<<"$OUT" && ok || bad "B6: $OUT"
grep -qi 'no fail' <<<"$OUT" && bad "B6 reads as no failures: $OUT" || ok
[ "$ST" = unknown ] && ok || bad "B6 state=$ST"

# ── B7 knob off ──
reset
REVIEW_LEVEL_E2E_RATCHET=0 section
grep -qx 'off (review.e2e_ratchet=0)' <<<"$OUT" && ok || bad "B7: $OUT"
[ "$ST" = off ] && ok || bad "B7 state=$ST"
[ "$CALLS" = 0 ] && ok || bad "B7 calls=$CALLS"

# ── B8 call budget ──
reset
run "E2E Tests" 4411 push "$MAINSHA" failure | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" failure | runs | fx "$HEADLIST"
jobs 4411 5 9001; jobs 5001 5 9101
for j in 9001 9002 9003 9004 9005; do log "$j" "$B12"; done
for j in 9101 9102 9103 9104 9105; do log "$j" "$B12"; done
section
[ "$CALLS" -le 6 ] && ok || bad "B8 calls=$CALLS: $(cat "$T/calls")"
grep -q '^main: .*1 of 5 failed jobs read' <<<"$OUT" && ok || bad "B8 main incomplete note: $OUT"
grep -q '^head: .*1 of 5 failed jobs read' <<<"$OUT" && ok || bad "B8 head incomplete note: $OUT"

# ── B9 no E2E run on the head ──
reset
run "E2E Tests" 4411 push "$MAINSHA" success | runs | fx "$MAINLIST"
run CI 5000 pull_request "$HEAD" success | runs | fx "$HEADLIST"
section
grep -q '^head: no completed E2E-class run for bbbbbbbb' <<<"$OUT" && ok || bad "B9: $OUT"
grep -q '^regression' <<<"$OUT" && bad "B9 regression list with no head run: $OUT" || ok

# ── B10 a cancelled head run is no evidence ──
reset
run "E2E Tests" 4411 push "$MAINSHA" success | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" cancelled | runs | fx "$HEADLIST"
section
grep -q '^head: no completed E2E-class run for bbbbbbbb' <<<"$OUT" && ok || bad "B10 cancelled head read as a run: $OUT"
grep -q '^regression' <<<"$OUT" && bad "B10 regression list from a cancelled run: $OUT" || ok

# ── B11 more than 30 failing specs: the cap is named ──
reset
run "E2E Tests" 4411 push "$MAINSHA" failure | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" success | runs | fx "$HEADLIST"
jobs 4411 1 9001
many=(); for i in $(seq 1 35); do many+=("e2e/m$i.spec.ts:1:1 › M › t$i"); done
log 9001 "${many[@]}"
section
grep -q '^main: .*; 30 failing spec(s); first 30 of 35 spec ids kept' <<<"$OUT" && ok || bad "B11 cap not named: $OUT"
grep -q '^note: not every failing spec on main was read' <<<"$OUT" && ok || bad "B11 no note: $OUT"

# ── B12 call budget knob ──
reset
run "E2E Tests" 4411 push "$MAINSHA" failure | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" failure | runs | fx "$HEADLIST"
jobs 4411 1 9001; jobs 5001 1 9101; log 9001 "$A"; log 9101 "$A"
REVIEW_LEVEL_E2E_BASELINE_CALLS=2 section
[ "$CALLS" -le 2 ] && ok || bad "B12 calls=$CALLS: $(cat "$T/calls")"
[ "$RC" = 0 ] && ok || bad "B12 rc=$RC"
grep -q 'call budget of 2 spent' <<<"$OUT" && ok || bad "B12 budget not named: $OUT"
grep -q '^  - ' <<<"$(under 'pre-existing')$(under 'regression')" && bad "B12 compared with no ids read: $OUT" || ok

# ── B13 runs-per-list knob ──
reset
run CI 4400 push "$MAINSHA" success | runs | fx "repos/$REPO/actions/runs?branch=main&status=completed&per_page=20"
REVIEW_LEVEL_E2E_BASELINE_RUNS=20 section
grep -qx 'none: no E2E-class workflow run on main in the last 20 completed runs' <<<"$OUT" && ok || bad "B13 per_page=20: $OUT / $(cat "$T/calls" 2>/dev/null)"
reset
run CI 4400 push "$MAINSHA" success | runs | fx "$MAINLIST"
REVIEW_LEVEL_E2E_BASELINE_RUNS=500 section
grep -qx 'none: no E2E-class workflow run on main in the last 50 completed runs' <<<"$OUT" && ok || bad "B13 bad value did not fall back to 50: $OUT"

# ── B14 ids and jobs knobs ──
reset
run "E2E Tests" 4411 push "$MAINSHA" failure | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" success | runs | fx "$HEADLIST"
jobs 4411 5 9001
for j in 9001 9002 9003 9004 9005; do log "$j" "e2e/j$j.spec.ts:1:1 › J › t"; done
REVIEW_LEVEL_E2E_BASELINE_IDS=3 REVIEW_LEVEL_E2E_BASELINE_JOBS=4 REVIEW_LEVEL_E2E_BASELINE_CALLS=9 section
grep -q '^main: .*; 3 failing spec(s); first 3 of 4 spec ids kept; 4 of 5 failed jobs read' <<<"$OUT" && ok || bad "B14: $OUT"

# ── B15 emb_prompt_file ──
reset
run "E2E Tests" 4411 push "$MAINSHA" success | runs | fx "$MAINLIST"
run "E2E Tests" 5001 pull_request "$HEAD" success | runs | fx "$HEADLIST"
(cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" JOBS_URL= GH_ETAG=0 TMPDIR="$T/tmp" LOG="$T/b15.err" bash -c \
  'log() { echo "$*" >> "$0.log"; }; key=example-org/project-6#7; . "$HARNESS/bin/lib/e2e-main-baseline.sh" || exit 9
   emb_prompt_file "$1" "$2" project-6 "$0"' "$T/b15.out" "$REPO" "$HEAD"); rc=$?
[ "$rc" = 0 ] && ok || bad "B15 rc=$rc"
grep -q '^main: E2E Tests run 4411 ' "$T/b15.out" && ok || bad "B15 section not written: $(cat "$T/b15.out" 2>/dev/null)"
grep -qx 'example-org/project-6#7: main e2e yes' "$T/b15.out.log" && ok || bad "B15 log line: $(cat "$T/b15.out.log" 2>/dev/null)"
(HARNESS="$HB" bash -c '. "$HARNESS/bin/lib/e2e-main-baseline.sh"; emb_prompt_file a/b abc1234 p ""') && bad "B15 no <out> did not fail" || ok

# ── M1 mutation: no :line:col strip -> B2 red ──
# A second closure root, mutated in place, so HB stays as shipped.
HM="$T/hm"; mkdir -p "$HM/catalog"
scratch_install_closure bin/lib/e2e-main-baseline.sh "$HM" >/dev/null || bad "M1 closure"
cp "$SRC"/catalog/review-*.tsv "$HM/catalog/"
sed -i -E 's/^(.*# emb-mutate: line-col.*)$/: # mutated/' "$HM/bin/lib/e2e-main-baseline.sh"
if cmp -s "$SRC/bin/lib/e2e-main-baseline.sh" "$HM/bin/lib/e2e-main-baseline.sh"; then
  bad "M1 the mutation anchor '# emb-mutate: line-col' is missing"
else
  reset
  run "E2E Tests" 4411 push "$MAINSHA" failure | runs | fx "$MAINLIST"
  run "E2E Tests" 5001 pull_request "$HEAD" failure | runs | fx "$HEADLIST"
  jobs 4411 1 9001; jobs 5001 1 9101; log 9001 "$B12"; log 9101 "$B14"
  HB="$HM" section
  grep -q '^main: E2E Tests run 4411 ' <<<"$OUT" && ok || bad "M1 the mutated lib did not run: $OUT"
  grep -q '^  - ' <<<"$(under 'pre-existing')" && bad "M1 B2 stayed green with no line:col strip: $OUT" || ok
fi

echo "e2e-main-baseline.bh-7941: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

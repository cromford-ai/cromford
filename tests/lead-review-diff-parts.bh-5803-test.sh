#!/bin/bash
# tests/lead-review-diff-parts.bh-5803-test.sh — a full-review diff over
# LEAD_REVIEW_DIFF_MAX_BYTES is read in parts (bin/lib/lead-diff-parts.sh), and
# a PR whose own tests do not fit gets a mechanical "split required" BLOCK with
# no model call. Drives the REAL bin/lead-review.sh tick against a scratch
# harness (scratch_install_closure), with these stubbed:
#   * curl  — the jobs worker
#   * gh    — the REST read of pulls/<n>
#   * bin/agent-call.sh — counts calls and keeps each prompt
#
#   A1  600 KB diff: one agent call; `## Diff coverage` before `## Diff`; the
#       planned file, then both tests, in that order; bin/zeta.sh and the
#       fixture's content are not in the prompt; the coverage lists both with
#       their bytes; the report header names bin/zeta.sh; the prompt carries the
#       "outside your verdict" rule; the coverage + diff fit the limit.
#   A2  the tests do not fit: no agent call; result done/BLOCK with
#       reviewer_model none:split-required; [BLOCK split-required]; a proposed
#       split of 2+ parts, each at or under the cap, alpha's test with alpha;
#       the last line is VERDICT: BLOCK.
#   R1  a 50 KB diff: `## Diff` then the whole diff, byte for byte; no coverage
#       section, no truncation line.
#   R2  the lib is not on the box: NO agent call and a split-required BLOCK that
#       names the reason; the cut diff never reaches a reviewer (lead review
#       BLOCK at b5426ef9d: the cut path could get a bare MERGE). TEST-CHANGE:
#       this case asserted the old cut before.
#   R2b git cannot list the diff (ldp_build rc 1): the same split-required BLOCK
#   R2c the coverage lists outgrow the reserve: a `## Diff coverage` prompt, never
#       the cut diff
#   R2d delta mode over the limit: the same split-required BLOCK, no cut delta
#   P1  the operator's decision on #5803: nothing merges unread. One unread bin/ file
#       (bin/zeta.sh) is split required with no model call, and the finding
#       names the file. TEST-CHANGE: A1 used to assert a MERGE-WITH-NOTES review
#       with bin/zeta.sh unread; A1 now uses PR 45, where only a fixture is unread.
#   P2  only a fixture (digest) is unread: read in parts, reviewed, may merge
#   C1  defense in depth: a lib that returns 0 with a file not read (mutation)
#       still gives split required, never a model call
#   R3  delta mode: ## Prior lead report and ## Delta, no ## Diff coverage.
#   M1  mutation: the tier order reversed in the lib makes A1's order red.
#   M2  mutation: a lib that always returns 0 makes A2 red.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-diff-parts.bh-5803-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/lead-diff-parts.sh prompts/lead-review.md; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
LIB="$SRC/bin/lib/lead-diff-parts.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# These cases review PR 41 more often than the per-PR-day tripwire allows.
export LEAD_REVIEW_MAX_PER_PR_DAY=50
# TEST-CHANGE (BH-8533): part review is on by default and would read these
# over-limit heads in parts. This suite pins the split-required path, so it
# runs with part review off (tests/lead-part-review.bh-8533-test.sh covers on).
export LEAD_REVIEW_PART_REVIEW_ENABLED=0
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DIFF_MAX_BYTES PLAN_CONTEXT_HOTSPOT_TOP

HB="$T/h"; mkdir -p "$HB/bin" "$HB/prompts" "$HB/catalog/lanes.d" "$HB/state" "$T/repos" "$T/tmp" "$T/fakebin" "$T/log"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
cp "\${6#@}" "$T/log/prompt.\$(wc -l < "$T/log/agent-count" | tr -d ' ')"
printf 'Findings\n- none\n\nVERDICT: %s\n' "\$(cat "$T/answer.verdict" 2>/dev/null || echo MERGE-WITH-NOTES)" > "\$5"
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
[ -f "$HB/bin/lib/lead-diff-parts.sh" ] && ok || bad "the closure of bin/lead-review.sh does not carry bin/lib/lead-diff-parts.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
echo box-demo > "$HB/state/box-name"
printf 'cromford example-org/cromford https://bh.test /api/board 1 box-demo\n' > "$HB/fleet.conf"

# fill <file> <bytes> <tag> [first-line] — deterministic text of about <bytes>
fill() {
  mkdir -p "$(dirname "$1")"
  { [ -n "${4:-}" ] && printf '%s\n' "$4"
    awk -v n="$2" -v t="$3" 'BEGIN { l = 0; while (l < n) { s = sprintf("%s row %07d filler\n", t, l); printf "%s", s; l += length(s) } }'; } > "$1"
}
O="$T/origin.git"; W="$T/work"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# cromford fixture\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
# pr <n> <test-bytes> — the 600 KB shape; prints the head sha
pr() {
  git -C "$W" checkout -q -B "pr$1" main
  mkdir -p "$W/.harness/specs/BH-9001"
  printf '# BH-9001 plan\n\nChange bin/alpha.sh and add its test.\n' > "$W/.harness/specs/BH-9001/plan.md"
  fill "$W/bin/alpha.sh" 120000 ALPHA
  fill "$W/bin/zeta.sh" "${ZETA:-250000}" ZETA
  fill "$W/tests/alpha-test.sh" "$2" ATEST 'bash bin/alpha.sh --check'
  fill "$W/tests/zeta-test.sh" "$2" ZTEST
  fill "$W/tests/fixtures/big.json" 110000 FIXTURE-MARKER-5803
  git -C "$W" add -A; git -C "$W" commit -qm "pr $1"
  git -C "$W" push -q -f "$O" "HEAD:refs/pull/$1/head"
  git -C "$W" rev-parse HEAD
}
SHA1=$(pr 41 60000)
SHA5=$(ZETA=100000 pr 45 60000)
SHA2=$(pr 42 200000)
git -C "$W" checkout -q -B pr43 main; fill "$W/bin/small.sh" 50000 SMALL; git -C "$W" add -A; git -C "$W" commit -qm small
git -C "$W" push -q -f "$O" HEAD:refs/pull/43/head; SHA3=$(git -C "$W" rev-parse HEAD)
G4=$(pr 44 60000)
echo 'one more line' >> "$W/bin/alpha.sh"; git -C "$W" commit -qam delta; git -C "$W" push -q -f "$O" HEAD:refs/pull/44/head
SHA4=$(git -C "$W" rev-parse HEAD)
git clone -q "$O" "$T/repos/cromford"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/conflict-hotspots"*) out='{"hotspots":[],"run":null,"total":0,"limit":10,"truncated":false}' ;;
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

LLOG="$HB/logs/lead-review.log"
# setup <pr> <sha> [scope-notes] — one request, a clean slate, the real lane and lib
setup() {
  rm -f "$T/log"/* "$LLOG"
  scratch_rm "$HB/state/lead-reviews"
  cp "$SRC/bin/lead-review.sh" "$HB/bin/"
  rm -f "$HB/bin/lib/lead-diff-parts.sh"; scratch_install_closure bin/lead-review.sh "$HB" >/dev/null
  echo "$2" > "$T/livehead"
  jq -nc --argjson p "$1" --arg s "$2" --arg n "${3:-only the lane}" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:$p,head_sha:$s,
    scope_notes:$n,prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
}
tick() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_DIFF_MAX_BYTES=${DMAX:-400000} bash "$HB/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
}
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
result() { grep '^POST /api/lead-reviews/lr-1/result ' "$T/log/worker" 2>/dev/null | tail -n 1 | cut -d' ' -f3-; }
P1="$T/log/prompt.1"
off() { grep -bF -- "$1" "$P1" 2>/dev/null | head -n 1 | cut -d: -f1; }
lno() { grep -nx -- "$1" "$P1" 2>/dev/null | head -n 1 | cut -d: -f1; }
dsz() { git -C "$W" diff "main...$1" -- "$2" | wc -c | tr -d ' '; }

# ── A1: over the limit, everything but a fixture fits: read in parts (PR 45) ──
setup 45 "$SHA5"; tick
[ "$RC" -eq 0 ] && ok || bad "A1 rc=$RC out=$(cat "$T/out")"
[ "$(agents)" = 1 ] && ok || bad "A1 agent called $(agents) time(s): $(cat "$LLOG" 2>/dev/null)"
cv=$(lno '## Diff coverage'); df=$(lno '## Diff')
[ -n "$cv" ] && [ -n "$df" ] && [ "$df" -gt "$cv" ] && ok || bad "A1 ## Diff coverage=$cv ## Diff=$df"
oa=$(off 'diff --git a/bin/alpha.sh'); ta=$(off 'diff --git a/tests/alpha-test.sh'); tz=$(off 'diff --git a/tests/zeta-test.sh'); oz=$(off 'diff --git a/bin/zeta.sh')
[ -n "$oa" ] && [ -n "$ta" ] && [ -n "$tz" ] && [ -n "$oz" ] && [ "$oa" -lt "$ta" ] && [ "$ta" -lt "$tz" ] && [ "$tz" -lt "$oz" ] \
  && ok || bad "A1 order alpha=$oa alpha-test=$ta zeta-test=$tz zeta=$oz (plan, tests, rest)"
grep -qF 'FIXTURE-MARKER-5803' "$P1" 2>/dev/null && bad "A1 the fixture's content reached the prompt" || ok
fx=$(git -C "$W" diff "main...$SHA5" -- tests/fixtures/big.json | wc -c | tr -d ' ')
grep -qxF -- "- tests/fixtures/big.json ($fx bytes)" "$P1" 2>/dev/null && ok || bad "A1 fixture not in the digest ($fx): $(sed -n '/^Digest/,/^## Diff$/p' "$P1")"
grep -qx 'Not read: none.' "$P1" 2>/dev/null && ok || bad "A1 coverage must say Not read: none.: $(sed -n '/^## Diff coverage$/,/^## Diff$/p' "$P1")"
grep -q '(diff truncated' "$P1" 2>/dev/null && bad "A1 the old truncation line is in the prompt" || ok
grep -qF 'is outside your verdict' "$P1" 2>/dev/null && ok || bad "A1 the prompt lacks the 'outside your verdict' rule"
tailsz=$(sed -n '/^## Diff coverage$/,$p' "$P1" | wc -c | tr -d ' ')
[ "$tailsz" -le 400000 ] && ok || bad "A1 coverage + diff is $tailsz bytes, over 400000"
REP="$HB/state/lead-reviews/lr-45-${SHA5:0:12}.md"
grep -q '^- diff read in parts: [0-9]* of [0-9]* files; not read: none; digest: 1 files$' "$REP" 2>/dev/null \
  && ok || bad "A1 report header: $(grep 'diff read' "$REP" 2>/dev/null)"
result | grep -q '"outcome":"done","verdict":"MERGE-WITH-NOTES"' && ok || bad "A1 result: $(result)"
grep -q 'lr-45-[0-9a-f]*: diff [0-9]* over 400000: read in parts, 0 files not read$' "$LLOG" 2>/dev/null && ok || bad "A1 log: $(grep 'over 400000' "$LLOG")"
# P2: with only a fixture unread, a MERGE stays a MERGE: nothing that is code went unread.
setup 45 "$SHA5"; echo MERGE > "$T/answer.verdict"; tick; rm -f "$T/answer.verdict"
result | grep -q '"verdict":"MERGE"' && ok || bad "P2 only a fixture unread: MERGE must stand: $(result)"

# ── P1: one unread bin/ file: split required, the finding names it (the operator, #5803) ──
setup 41 "$SHA1"; tick
REP="$HB/state/lead-reviews/lr-41-${SHA1:0:12}.md"
[ ! -f "$T/log/agent-count" ] && ok || bad "P1 the agent was called $(agents) time(s) with bin/zeta.sh unread"
jq -e '.outcome == "done" and .verdict == "BLOCK" and .reviewer_model == "none:split-required"' <<<"$(result)" >/dev/null 2>&1 \
  && ok || bad "P1 result: $(result)"
grep -qE -- '^- \[BLOCK split-required\] 1 file that is not a test does not fit .*bin/zeta\.sh' "$REP" 2>/dev/null \
  && ok || bad "P1 the finding must name bin/zeta.sh: $(grep -F 'BLOCK' "$REP" 2>/dev/null)"
[ "$(grep -c '^- \[BLOCK' "$REP" 2>/dev/null)" = 1 ] && ok || bad "P1 more than one BLOCK line"
grep -qx '## Proposed split' "$REP" 2>/dev/null && grep -qF 'bin/zeta.sh (' "$REP" && ok || bad "P1 no proposed split naming bin/zeta.sh"
[ "$(grep -v '^[[:space:]]*$' "$REP" 2>/dev/null | tail -n 1)" = "VERDICT: BLOCK" ] && ok || bad "P1 last line: $(tail -n 1 "$REP")"

# ── A2: the tests do not fit: split required, no model call ──
setup 42 "$SHA2"; tick
[ "$RC" -eq 0 ] && ok || bad "A2 rc=$RC out=$(cat "$T/out")"
[ ! -f "$T/log/agent-count" ] && ok || bad "A2 the agent was called $(agents) time(s)"
R=$(result)
jq -e '.outcome == "done" and .verdict == "BLOCK" and .reviewer_model == "none:split-required"' <<<"$R" >/dev/null 2>&1 \
  && ok || bad "A2 result: $R"
REP="$HB/state/lead-reviews/lr-42-${SHA2:0:12}.md"
grep -qF -- '- [BLOCK split-required] 1 of 2 test files do not fit the 400000-byte review limit; this is not a finding on the code.' "$REP" 2>/dev/null \
  && ok || bad "A2 no split finding: $(grep -F 'split-required' "$REP" 2>/dev/null)"
[ "$(grep -c '^- \[BLOCK' "$REP" 2>/dev/null)" = 1 ] && ok || bad "A2 a content BLOCK besides the split finding"
grep -qx '## Proposed split' "$REP" 2>/dev/null && ok || bad "A2 no ## Proposed split"
grep -qx '## Diff coverage' "$REP" 2>/dev/null && ok || bad "A2 no ## Diff coverage in the report"
grep -qx -- '- review mode: split required (the PR'"'"'s own tests do not fit LEAD_REVIEW_DIFF_MAX_BYTES=400000)' "$REP" 2>/dev/null \
  && ok || bad "A2 review mode line: $(grep 'review mode' "$REP" 2>/dev/null)"
parts=$(grep -cE '^- Part [0-9]+ \(' "$REP" 2>/dev/null)
[ "${parts:-0}" -ge 2 ] && ok || bad "A2 $parts parts proposed"
awk '/^- Part [0-9]+ \(/ { n = $4; gsub(/[^0-9]/, "", n); if (n + 0 > 400000 - 32768) bad = 1 } END { exit bad }' "$REP" \
  && ok || bad "A2 a part is over the cap: $(grep '^- Part' "$REP")"
grep -E '^- Part [0-9]+ \(' "$REP" | grep -F 'bin/alpha.sh (' | grep -qF 'tests/alpha-test.sh (' && ok || bad "A2 alpha's test is not in alpha's part: $(grep '^- Part' "$REP")"
[ "$(grep -v '^[[:space:]]*$' "$REP" 2>/dev/null | tail -n 1)" = "VERDICT: BLOCK" ] && ok || bad "A2 last line: $(tail -n 1 "$REP")"
grep -qE 'lr-42-[0-9a-f]*: split required \(1 test files not read(, 1 other files not read)?\); no model call$' "$LLOG" 2>/dev/null && ok || bad "A2 log: $(grep -i split "$LLOG")"

# ── R1: under the limit: the prompt ends with the whole diff, as before ──
setup 43 "$SHA3"; tick
[ "$(agents)" = 1 ] && ok || bad "R1 agent called $(agents) time(s)"
{ printf '\n## Diff\n'; git -C "$W" diff "main...$SHA3"; } > "$T/r1.want"
w=$(wc -c < "$T/r1.want" | tr -d ' ')
tail -c "$w" "$P1" 2>/dev/null | cmp -s - "$T/r1.want" && ok || bad "R1 the prompt does not end with ## Diff and the whole diff"
grep -q '^## Diff coverage$\|(diff truncated' "$P1" 2>/dev/null && bad "R1 parts mode ran under the limit" || ok

# split_block <case> <reason-ERE> — no model call, a split-required BLOCK naming the reason, no cut diff
split_block() {
  [ ! -f "$T/log/agent-count" ] && ok || bad "$1 the agent was called $(agents) time(s) on a diff it could not read in parts"
  jq -e '.outcome == "done" and .verdict == "BLOCK" and .reviewer_model == "none:split-required"' <<<"$(result)" >/dev/null 2>&1 \
    && ok || bad "$1 result: $(result)"
  grep -qE -- "^- \\[BLOCK split-required\\] .*$2" "$REP" 2>/dev/null && ok || bad "$1 no split-required line naming /$2/: $(grep -F 'BLOCK' "$REP" 2>/dev/null)"
  grep -q '(diff truncated' "$REP" 2>/dev/null && bad "$1 the report carries a cut diff" || ok
  [ "$(grep -v '^[[:space:]]*$' "$REP" 2>/dev/null | tail -n 1)" = "VERDICT: BLOCK" ] && ok || bad "$1 last line: $(tail -n 1 "$REP" 2>/dev/null)"
}
# ── R2: no lib on the box: a split-required BLOCK, never the cut ──
setup 41 "$SHA1"; rm -f "$HB/bin/lib/lead-diff-parts.sh"; tick
REP="$HB/state/lead-reviews/lr-41-${SHA1:0:12}.md"
split_block R2 'bin/lib/lead-diff-parts.sh is not loaded'
grep -q 'bin/lib/lead-diff-parts.sh missing' "$LLOG" 2>/dev/null && ok || bad "R2 log does not name the missing lib: $(cat "$LLOG")"
# ── R2b: git cannot list the diff in parts: the same BLOCK ──
setup 41 "$SHA1"
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in *" --numstat "*) echo "fatal: fixture numstat failure" >&2; exit 128 ;; esac
exec /usr/bin/git "\$@"
EOF
chmod +x "$T/fakebin/git"; tick; rm -f "$T/fakebin/git"
split_block R2b 'could not be read in parts [(]rc 1[)]'
# ── R2c: the coverage lists outgrow the reserve: still a coverage prompt ──
setup 45 "$SHA5"; sed -i 's/^LDP_RESERVE=32768 /LDP_RESERVE=10 /' "$HB/bin/lib/lead-diff-parts.sh"; tick
[ "$(agents)" = 1 ] && ok || bad "R2c agent called $(agents) time(s): $(tail -3 "$LLOG")"
grep -qx '## Diff coverage' "$P1" 2>/dev/null && ok || bad "R2c no ## Diff coverage in the prompt"
grep -q '(diff truncated' "$P1" 2>/dev/null && bad "R2c the cut diff reached the reviewer" || ok
tailsz=$(sed -n '/^## Diff coverage$/,$p' "$P1" | wc -c | tr -d ' ')
[ "$tailsz" -le 400000 ] && ok || bad "R2c coverage + diff is $tailsz bytes, over 400000"
# ── C1: a lib that lets an unread file through (rc 0) still gives split required ──
setup 41 "$SHA1"
sed 's/^  if \[ -z "\$LDP_UNREAD" \] || { \[ "\$any" != any \] && \[ "\$LDP_TEST_UNREAD" -eq 0 \]; }; then rm -rf "\$d"; return 0; fi$/  rm -rf "$d"; return 0/' "$LIB" > "$HB/bin/lib/lead-diff-parts.sh"
if cmp -s "$HB/bin/lib/lead-diff-parts.sh" "$LIB"; then bad "C1 mutation anchor missing"
else
  echo MERGE > "$T/answer.verdict"; tick; rm -f "$T/answer.verdict"
  REP="$HB/state/lead-reviews/lr-41-${SHA1:0:12}.md"
  [ ! -f "$T/log/agent-count" ] && ok || bad "C1 a lib rc 0 with bin/zeta.sh unread reached the model"
  jq -e '.verdict == "BLOCK" and .reviewer_model == "none:split-required"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "C1 result: $(result)"
  grep -qF 'bin/zeta.sh' "$REP" 2>/dev/null && ok || bad "C1 the finding must name bin/zeta.sh"
fi

# ── R3: delta mode is unchanged ──
setup 44 "$SHA4" "lead-delta:$G4"; mkdir -p "$HB/state/lead-reviews"
printf '# Lead review lr-44-%s (example-org/cromford#44 at %s)\n\n- verdict: MERGE\n\nFindings\n- none\n\nVERDICT: MERGE\n' "${G4:0:12}" "$G4" \
  > "$HB/state/lead-reviews/lr-44-${G4:0:12}.md"
tick
[ "$(agents)" = 1 ] && ok || bad "R3 agent called $(agents) time(s): $(cat "$LLOG")"
grep -qx '## Prior lead report' "$P1" 2>/dev/null && grep -qx '## Delta' "$P1" && ok || bad "R3 not a delta prompt: $(grep 'delta' "$LLOG")"
grep -q '^## Diff coverage$' "$P1" 2>/dev/null && bad "R3 a coverage section in delta mode" || ok

# ── R2d: delta mode over the limit: the same BLOCK, never a cut delta ──
setup 44 "$SHA4" "lead-delta:$G4"; mkdir -p "$HB/state/lead-reviews"
printf '# Lead review lr-44-%s (example-org/cromford#44 at %s)\n\n- verdict: MERGE\n\nFindings\n- none\n\nVERDICT: MERGE\n' "${G4:0:12}" "$G4" \
  > "$HB/state/lead-reviews/lr-44-${G4:0:12}.md"
DMAX=300 tick
REP="$HB/state/lead-reviews/lr-44-${SHA4:0:12}.md"
split_block R2d 'delta'

# ── M1: tier order reversed in the lib -> A1's order red ──
setup 45 "$SHA5"
sed 's/for t in plan test rest; do/for t in rest test plan; do/' "$LIB" > "$HB/bin/lib/lead-diff-parts.sh"
if cmp -s "$HB/bin/lib/lead-diff-parts.sh" "$LIB"; then bad "M1 mutation anchor missing"
else
  tick
  [ "$(agents)" = 1 ] && ok || bad "M1 the mutated lane made no model call, so the order check below proves nothing"
  oa=$(off 'diff --git a/bin/alpha.sh'); ta=$(off 'diff --git a/tests/alpha-test.sh'); tz=$(off 'diff --git a/tests/zeta-test.sh')
  [ -n "$oa" ] && [ -n "$ta" ] && [ -n "$tz" ] && [ "$oa" -lt "$ta" ] && [ "$ta" -lt "$tz" ] \
    && bad "M1 A1's order stayed green with the tiers reversed" || ok
fi

# ── M2: a lib that never says split -> the lane still answers split required ──
# TEST-CHANGE: M2 asserted that this mutation reached the model (A2 went red).
# Since the operator's decision on #5803 the lane itself refuses any unread file, so the
# same mutation must still give split required with no model call (see C1).
setup 42 "$SHA2"
sed 's/^  return 2$/  return 0/' "$LIB" > "$HB/bin/lib/lead-diff-parts.sh"
if cmp -s "$HB/bin/lib/lead-diff-parts.sh" "$LIB"; then bad "M2 mutation anchor missing"
else
  tick
  [ ! -f "$T/log/agent-count" ] && ok || bad "M2 a lib that never says split reached the model with tests unread"
  jq -e '.verdict == "BLOCK" and .reviewer_model == "none:split-required"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "M2 result: $(result)"
fi

echo "lead-review-diff-parts.bh-5803: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

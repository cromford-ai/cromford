#!/bin/bash
# tests/lead-checklist-hardcoded-knob.bh-7945-test.sh — BH-7945: a literal
# limit, rate, threshold, price, timeout, cap or max_tokens with no DB row or
# knob read is [BLOCK hardcoded-knob]. A replay over the fixture set in
# tests/fixtures/lead-checklist-hardcoded-knob.bh-7945/ (the bh-5271 shape: a
# base tree, one .diff per case, expected.txt <case> :: BLOCK|NONE).
#
# FREE MODE (default, CI). Each case is a PR on a scratch origin. The REAL
# bin/lead-review.sh tick composes the prompt and writes the report, with curl,
# gh and bin/agent-call.sh stubbed (the stub answers from $T/answer.<case>).
#   K1  the prompt's item 4 says [BLOCK hardcoded-knob], keeps [BLOCK model-id]
#       and the ${KNOB:-literal} [NOTE], and no longer says the literal is a
#       [NOTE] a hardcoded threshold or rate;
#   K2  the prompt's ## Diff carries each case's added lines;
#   K3  end to end: the literal case's [BLOCK hardcoded-knob] answer stays a
#       BLOCK through rl_cap (report verdict BLOCK, line not demoted, rl_cap ran
#       with standing=1 untagged=0); the knob case's report is not BLOCK;
#   K4  rl_line_blocks / rl_cap over the real catalog: tagged, colon-tagged and
#       untagged-but-described literals stand; near misses do not;
#   K5  expected.txt is whole;
#   M1  mutation: [BLOCK hardcoded-knob] cut from item 4 turns K1 red; the
#       catalog row cut turns K4's mixed-report case red.
#   K6  bin/review-prs.sh and bin/lib/rb/review.sh name hardcoded-knob, and no
#       line that names it matches the merge conductor's iron-law pattern
#       (read from bin/lib/mc/classify.sh), so the edit cannot hold the PR;
#   M2  mutation: the class put back on the VERCEL_URL line turns K6 red.
#
# LIVE MODE (opt-in, metered). LEAD_CHECKLIST_EVAL_MODEL=<model> sends each
# composed prompt through bin/agent-call.sh (lane lead-review) and grades it:
# BLOCK = VERDICT: BLOCK and a [BLOCK hardcoded-knob] line; NONE = not BLOCK.
# Unset = live grading skipped.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-checklist-hardcoded-knob.bh-7945-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/lead-checklist-hardcoded-knob.bh-7945"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/review-level.sh prompts/lead-review-checklist.md catalog/review-always-block.tsv \
         tests/fixtures/lead-checklist-hardcoded-knob.bh-7945/expected.txt; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PLAN_CONTEXT_HOTSPOT_TOP AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_MAX_PER_TICK

# ── K5: expected.txt is whole ──
CASES=(); declare -A CLASS
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  c=${line%% :: *}; k=${line##* :: }
  [ "$c" != "$line" ] || { bad "K5 malformed expected line '$line'"; continue; }
  [ -f "$FX/$c.diff" ] && ok || bad "K5 $c has no $c.diff"
  case "$k" in BLOCK|NONE) ok ;; *) bad "K5 $c has class '$k'" ;; esac
  CASES+=("$c"); CLASS[$c]=$k
done < "$FX/expected.txt"
classes=" ${CLASS[*]} "
for k in BLOCK NONE; do
  [[ $classes == *" $k "* ]] && ok || bad "K5 no $k case in expected.txt"
done

# The canned answers the stub agent gives, per case. The literal one is the
# answer item 4 asks for; the knob one is a clean review with one note.
cat > "$T/answer.literal-max-tokens" <<'EOF'
Findings
- [BLOCK hardcoded-knob] src/interview.js:8: max_tokens: 1024 with no DB row or knob read; the fix needs the row interview.max_tokens.
- [NOTE] src/interview.js:5: answer() has no test.

VERDICT: BLOCK
EOF
cat > "$T/answer.knob-max-tokens" <<'EOF'
Findings
- [NOTE] src/interview.js:10: the fallback 1024 is the documented default of the row interview.max_tokens.

VERDICT: MERGE
EOF

# ── the scratch harness ──
HB="$T/h"; mkdir -p "$HB/bin" "$HB/prompts" "$HB/catalog/lanes.d" "$HB/state" "$T/repos" "$T/tmp" "$T/fakebin" "$T/log"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
c=\$(cat "$T/case")
cp "\${6#@}" "$T/log/prompt.\$c"
cp "$T/answer.\$c" "\$5"
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
# bin/lead-review.sh sources its optional libs (rl_cap among them) from libs.d/.
mkdir -p "$HB/bin/lib/lead-review"; cp -R "$SRC/bin/lib/lead-review/libs.d" "$HB/bin/lib/lead-review/"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$HB/catalog/lanes.d/"
cp "$SRC/catalog/review-always-block.tsv" "$HB/catalog/"
for f in review-nits.tsv review-golive.tsv; do [ -f "$SRC/catalog/$f" ] && cp "$SRC/catalog/$f" "$HB/catalog/"; done
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
echo box-demo > "$HB/state/box-name"
printf 'cromford example-org/cromford https://bh.test /api/board 1 box-demo\n' > "$HB/fleet.conf"

# One origin: base/ on main, case i on refs/pull/<200+i>/head.
OR="$T/origin.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
cp -R "$FX/base/." "$WK/"
git -C "$WK" add -A; git -C "$WK" commit -qm base; git -C "$WK" push -q "$OR" main
declare -A PRN HEAD
i=0
for c in "${CASES[@]}"; do
  i=$((i + 1)); PRN[$c]=$((200 + i))
  git -C "$WK" checkout -q -B "case-$c" main
  if git -C "$WK" apply --index "$FX/$c.diff" 2>"$T/apply.err"; then ok; else bad "$c.diff does not apply on base/: $(cat "$T/apply.err")"; continue; fi
  git -C "$WK" commit -qm "$c"
  HEAD[$c]=$(git -C "$WK" rev-parse HEAD)
  git -C "$WK" push -q "$OR" "HEAD:refs/pull/${PRN[$c]}/head"
done
git clone -q "$OR" "$T/repos/cromford"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
code=200; out='{}'
case "\$m \$p" in
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

# compose <case> — one real tick on that case's PR. The prompt lands in
# $T/log/prompt.<case>, the lead report in $T/log/report.<case>.
compose() {
  local c="$1" r
  echo "$c" > "$T/case"; echo "${HEAD[$c]}" > "$T/livehead"
  scratch_rm "$HB/state/lead-reviews"
  rm -f "$T/log/prompt.$c" "$T/log/report.$c"
  jq -nc --argjson p "${PRN[$c]}" --arg s "${HEAD[$c]}" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:$p,head_sha:$s,
    scope_notes:"eval",prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$HB/fleet.conf" \
      REVIEW_LEVEL_MODE=levels LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$HB/bin/lead-review.sh" tick ) > "$T/out.$c" 2>&1
  for r in "$HB"/state/lead-reviews/*.md; do [ -f "$r" ] && cp "$r" "$T/log/report.$c"; done
}
# item4 <file> — checklist item 4, from its line to item 5, on one line.
item4() { awk '/^4\. DB knobs/ {f=1} f && /^5\. / {exit} f' "$1" 2>/dev/null | tr '\n' ' ' | tr -s ' '; }

# check_k1 <case> <prompt> <tag>
check_k1() {
  local c="$1" P="$2" tag="$3" it
  [ -s "$P" ] || { bad "${tag:+$tag }K1 $c: no prompt composed: $(tail -5 "$T/out.$c" 2>/dev/null)"; return; }
  it=$(item4 "$P")
  [ -n "$it" ] || { bad "${tag:+$tag }K1 $c: the prompt has no item 4 (DB knobs)"; return; }
  grep -qF '[BLOCK hardcoded-knob] a new or changed literal limit, rate, threshold, price, timeout, cap or `max_tokens` with no DB row or knob read' <<<"$it" \
    && ok || bad "${tag:+$tag }K1 $c: item 4 lacks [BLOCK hardcoded-knob]: $it"
  grep -qF 'The literal may stay only as the documented fallback of a knob that exists.' <<<"$it" \
    && ok || bad "${tag:+$tag }K1 $c: item 4 lacks the fallback clause: $it"
  grep -qF '[BLOCK model-id] a `claude-*` model string in agent code.' <<<"$it" \
    && ok || bad "${tag:+$tag }K1 $c: item 4 lost [BLOCK model-id]: $it"
  grep -qF '[NOTE] a `${KNOB:-literal}` second copy of a default the knob registry already holds.' <<<"$it" \
    && ok || bad "${tag:+$tag }K1 $c: item 4 lost the \${KNOB:-literal} [NOTE]: $it"
  ! grep -qF '[NOTE] a hardcoded threshold or rate' <<<"$it" \
    && ok || bad "${tag:+$tag }K1 $c: item 4 still makes a hardcoded threshold a [NOTE]: $it"
}

for c in "${CASES[@]}"; do
  [ -n "${HEAD[$c]:-}" ] || continue
  compose "$c"
  P="$T/log/prompt.$c"
  check_k1 "$c" "$P" ""
  # ── K2: the case's added lines are in ## Diff ──
  d=$(awk '$0 == "## Diff" {f=1; next} f' "$P" 2>/dev/null)
  miss=""
  while IFS= read -r l; do grep -qxF -- "$l" <<<"$d" || miss="$l"; done < <(grep '^+[^+]' "$FX/$c.diff")
  [ -z "$miss" ] && ok || bad "K2 $c: ## Diff lacks '$miss'"
  # ── K3: the report through the real tick ──
  R="$T/log/report.$c"
  if [ ! -s "$R" ]; then bad "K3 $c: no lead report written: $(tail -5 "$T/out.$c")"; continue; fi
  v=$(sed -nE 's/^- verdict: //p' "$R" | head -1)
  case "${CLASS[$c]}" in
    BLOCK)
      [ "$v" = BLOCK ] && ok || bad "K3 $c: report verdict '$v', want BLOCK"
      grep -qF -- '- [BLOCK hardcoded-knob] src/interview.js:8: max_tokens: 1024 with no DB row or knob read' "$R" \
        && ok || bad "K3 $c: the [BLOCK hardcoded-knob] line was rewritten: $(grep -F 'interview.js:8' "$R")"
      ! grep -qF 'NOTE demoted from BLOCK hardcoded-knob' "$R" && ok || bad "K3 $c: the hardcoded-knob finding was demoted"
      # rl_cap ran (mode=levels) and read the line as a class-tagged BLOCK, not an untagged one it kept.
      grep -qE '^- review level \(BH-7123\): mode levels; mode=levels demoted=0 standing=1 verdict=BLOCK untagged=0' "$R" \
        && ok || bad "K3 $c: rl_cap did not run or did not read the class tag: $(grep '^- review level' "$R")"
      ! grep -qF 'has no fragment' "$HB/logs/lead-review.log" 2>/dev/null \
        && ok || bad "K3 $c: the tick found no libs.d fragment, so rl_cap never ran"
      ;;
    NONE)
      [ -n "$v" ] && [ "$v" != BLOCK ] && ok || bad "K3 $c: report verdict '$v', want not BLOCK" ;;
  esac
done
grep -qxF -- '+    max_tokens: 1024,' "$T/log/prompt.literal-max-tokens" 2>/dev/null && ok || bad "K2 the literal prompt lacks '+    max_tokens: 1024,'"

# ── K4: the decision table, on a catalog root ──
# k4 <root> <tag> — prints one FAIL line per miss on stdout.
k4() (
  root="$1" tag="$2"
  unset REVIEW_LEVEL_MODE JOBS_URL HARNESS_SECRET H
  export HARNESS="$root"
  . "$SRC/bin/lib/review-level.sh" || { echo "FAIL: ${tag:+$tag }K4 cannot source review-level.sh"; exit 0; }
  stand=(
    '- [BLOCK hardcoded-knob] src/interview.js:12: max_tokens: 1024 with no DB row or knob read'
    '- [BLOCK: hardcoded-knob] src/interview.js:12: max_tokens: 1024'
    '- [HIGH] src/brain.ts:40: max_tokens 900 is a literal with no settings row'
    '- [BLOCK] src/proposal.ts:8: hardcoded timeout of 30000 ms, no knob read'
  )
  nostand=(
    '- [BLOCK] src/card.tsx:12: card padding is 14 px, hardcoded'
    '- [BLOCK] src/i.ts:4: max_tokens read from settings row interview.max_tokens with 1024 fallback'
    '- [LOW] docs typo in the hardcoded-knobs heading'
    '- [MEDIUM] hardcoded threshold in a test fixture'
  )
  n=0
  for l in "${stand[@]}"; do n=$((n+1)); rl_line_blocks "$l" || echo "FAIL: ${tag:+$tag }K4 case $n does not stand: $l"; done
  for l in "${nostand[@]}"; do n=$((n+1)); ! rl_line_blocks "$l" || echo "FAIL: ${tag:+$tag }K4 case $n stands: $l"; done
  # The mixed report: grammar is on (a red-build tag), so anything without a class is demoted.
  f="$T/k4.$tag.md"
  { echo '- [BLOCK red-build] src/a.ts:3: typecheck fails on the new import.'
    printf '%s\n' "${stand[@]}" "${nostand[@]}"
    echo '- [NOTE] bin/x.sh:3: ${LIMIT:-50} second copy of a default the knob registry holds'
    echo 'TIER: 2'; echo 'VERDICT: BLOCK'; } > "$f"
  rl_cap "$f" cromford --approve APPROVE --block BLOCK --lens lead >/dev/null 2>&1
  n=0
  for l in "${stand[@]}"; do n=$((n+1)); grep -qxF -- "$l" "$f" || echo "FAIL: ${tag:+$tag }K4 mixed case $n was rewritten: $(sed -n "$((n+1))p" "$f")"; done
  for l in "${nostand[@]}"; do
    n=$((n+1)); [ "$n" = 7 ] && { grep -qxF -- "$l" "$f" || echo "FAIL: ${tag:+$tag }K4 mixed case 7 ([LOW]) was rewritten"; continue; }
    sed -n "$((n+1))p" "$f" | grep -qF 'NOTE demoted from' || echo "FAIL: ${tag:+$tag }K4 mixed case $n was not demoted: $(sed -n "$((n+1))p" "$f")"
  done
  grep -qxF -- '- [NOTE] bin/x.sh:3: ${LIMIT:-50} second copy of a default the knob registry holds' "$f" \
    || echo "FAIL: ${tag:+$tag }K4 mixed case 9 ([NOTE] \${LIMIT:-50}) was touched"
  grep -qE '^VERDICT: BLOCK$' "$f" || echo "FAIL: ${tag:+$tag }K4 mixed report verdict is not BLOCK"
)
mkdir -p "$T/root/catalog"; cp "$SRC/catalog/"review-*.tsv "$T/root/catalog/"
k4 "$T/root" "" > "$T/k4.out"
if [ -s "$T/k4.out" ]; then while IFS= read -r l; do bad "${l#FAIL: }"; done < "$T/k4.out"; else ok; fi

# ── M1: mutations turn K1 and K4 red ──
sed 's/\[BLOCK hardcoded-knob\] a new or changed literal/a new or changed literal/' \
  "$SRC/prompts/lead-review-checklist.md" > "$HB/prompts/lead-review-checklist.md"
if cmp -s "$HB/prompts/lead-review-checklist.md" "$SRC/prompts/lead-review-checklist.md"; then
  bad "M1 item 4 has no [BLOCK hardcoded-knob] to cut"
else
  c=${CASES[0]}; compose "$c"
  before=$FAIL
  check_k1 "$c" "$T/log/prompt.$c" "M1" > "$T/m1.out"
  FAIL=$before
  grep -q 'M1 K1 .*lacks \[BLOCK hardcoded-knob\]' "$T/m1.out" && ok || bad "M1 K1 stayed green with [BLOCK hardcoded-knob] cut from item 4: $(cat "$T/m1.out")"
fi
cp "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
grep -v '^hardcoded-knob	' "$SRC/catalog/review-always-block.tsv" > "$T/root/catalog/review-always-block.tsv"
if cmp -s "$T/root/catalog/review-always-block.tsv" "$SRC/catalog/review-always-block.tsv"; then
  bad "M1 the catalog has no hardcoded-knob row to cut"
else
  k4 "$T/root" M1 > "$T/m1k4.out"
  grep -q 'M1 K4 mixed case 1 was rewritten' "$T/m1k4.out" && ok || bad "M1 K4 mixed case 1 stayed green with the catalog row cut: $(cat "$T/m1k4.out")"
fi
cp "$SRC/catalog/review-always-block.tsv" "$T/root/catalog/"

# ── K6: the class lines in the PRS / rb prompts pass the conductor scan ──
IRON_RE=$(sed -nE 's/.*grep -cE "([^"]*VERCEL_URL[^"]*)".*/\1/p' "$SRC/bin/lib/mc/classify.sh" | head -1)
# k6 <file> <tag> — prints one FAIL line per miss on stdout.
k6() {
  local f="$1" tag="$2" hits
  [ -n "$IRON_RE" ] || { echo "FAIL: ${tag:+$tag }K6 no iron-law pattern found in bin/lib/mc/classify.sh"; return; }
  grep -q 'hardcoded-knob' "$f" || echo "FAIL: ${tag:+$tag }K6 $f does not name hardcoded-knob"
  hits=$(grep 'hardcoded-knob' "$f" | grep -cE "$IRON_RE")
  [ "$hits" = 0 ] || echo "FAIL: ${tag:+$tag }K6 $f: $hits line(s) name hardcoded-knob and match the iron-law scan"
}
for f in bin/review-prs.sh bin/lib/rb/review.sh; do
  k6 "$SRC/$f" "" > "$T/k6.out"
  if [ -s "$T/k6.out" ]; then while IFS= read -r l; do bad "${l#FAIL: }"; done < "$T/k6.out"; else ok; fi
done

# ── M2: the class back on the VERCEL_URL line turns K6 red ──
sed 's/model-id, weakened-test/model-id, hardcoded-knob, weakened-test/' "$SRC/bin/review-prs.sh" > "$T/m2-review-prs.sh"
if cmp -s "$T/m2-review-prs.sh" "$SRC/bin/review-prs.sh"; then
  bad "M2 bin/review-prs.sh has no 'model-id, weakened-test' list to mutate"
else
  k6 "$T/m2-review-prs.sh" M2 > "$T/m2.out"
  grep -q 'M2 K6 .*match the iron-law scan' "$T/m2.out" && ok || bad "M2 K6 stayed green with the class on the VERCEL_URL line: $(cat "$T/m2.out")"
fi

# ── LIVE MODE ──
if [ -z "${LEAD_CHECKLIST_EVAL_MODEL:-}" ]; then
  echo "live grading skipped: LEAD_CHECKLIST_EVAL_MODEL is not set (metered; the suite picks no model)"
else
  sed -n '/^lr_verdict() {/,/^}/p' "$SRC/bin/lead-review.sh" > "$T/lr-verdict.sh"
  . "$SRC/bin/lib/verdict-parse.sh" || bad "live: cannot source bin/lib/verdict-parse.sh"
  . "$T/lr-verdict.sh"
  command -v lr_verdict >/dev/null || bad "live: no lr_verdict in bin/lead-review.sh"
  for c in "${CASES[@]}"; do
    P="$T/log/prompt.$c"; out="$T/live.$c.out"
    [ -s "$P" ] || { bad "live $c: no composed prompt"; continue; }
    AGENT_CALL_ROLE=lead.review AGENT_CALL_LANE=lead-review \
      "$SRC/bin/agent-call.sh" lead-review cromford "$LEAD_CHECKLIST_EVAL_MODEL" 600 "$out" "@$P" >/dev/null 2>&1
    v=$(lr_verdict "$out")
    case "${CLASS[$c]}" in
      BLOCK) [ "$v" = BLOCK ] && grep -qiE '^\s*-\s*\[BLOCK[[:space:]:]+hardcoded-knob\]' "$out" \
               && ok || bad "live $c: want VERDICT BLOCK and a [BLOCK hardcoded-knob] line, got verdict $v" ;;
      NONE)  [ "$v" != BLOCK ] && [ "$v" != unknown ] && ok || bad "live $c: want not-BLOCK, got verdict $v" ;;
    esac
    printf 'live %-20s want %-6s verdict %s\n' "$c" "${CLASS[$c]}" "$v"
  done
fi

echo "lead-checklist-hardcoded-knob.bh-7945: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

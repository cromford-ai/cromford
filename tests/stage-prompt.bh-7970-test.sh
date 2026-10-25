#!/usr/bin/env bash
# contract-test
# tests/stage-prompt.bh-7970-test.sh — BH-7970 (BH-7940.2): the plan, execute,
# review, fix-round and qa stage prompts live in prompts/stages/<kind>.md and
# render through sp_render (bin/lib/stage-prompt.sh).
#
# The byte-equal cases are a CONTRACT PIN. They run the OLD inline builders,
# kept verbatim in tests/fixtures/stage-prompt.bh-7970/ (captured from
# c73cc1b2), and the NEW marker blocks extracted from the current scripts, with
# the same variable values and the same helper stubs, and `cmp` the two prompts.
# A later ticket that edits a template on purpose updates the matching fixture
# in the same diff.
#
# Cases: byte-equal-plan mutation-plan byte-equal-execute byte-equal-review
# byte-equal-fix-round byte-equal-qa render-whitelist no-eval
# no-trailing-newline missing-template-refuses missing-template-refuses-stage
# qa-refuses-no-empty-prompt resolved-wins absent-falls-back empty-falls-back
# rules-pointer-present rules-pointer-absent fixture-provenance block-order
# review-others-inline resolver-reads-template
#
# No network, no vendor, no live harness: every helper and CC are stubs, and
# every file is written under this run's own scratch dir.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/stage-prompt.sh"
FX="$DIR/tests/fixtures/stage-prompt.bh-7970"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
casepass() { echo "ok   $1"; }

H="$T/h"; mkdir -p "$H/state/prompts" "$T/build" "$T/cwd/bin" "$T/empty"
# The plan builder runs `bin/size-scope.sh --rules` from its cwd (a backtick
# command substitution in the old string), so the cwd carries a stub of it.
printf '#!/bin/sh\nprintf "<size-scope:%%s>" "$*"\n' > "$T/cwd/bin/size-scope.sh"
chmod +x "$T/cwd/bin/size-scope.sh"

# Extract a `# >>> <name>` ... `# <<< <name>` marker block.
xb() { awk -v s="# >>> $2" -v e="# <<< $2" 'index($0,s)==1{f=1;next} index($0,e)==1{exit} f' "$1" > "$3"; }
xb "$DIR/bin/lib/rb/plan.sh" 'plan prompt' "$T/plan-block.sh"
xb "$DIR/bin/lib/rb/execute.sh" 'execute prompt' "$T/exec-block.sh"
xb "$DIR/bin/lib/rb/review.sh" 'review prompt' "$T/review-block.sh"
awk '/^LENS_VARS\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/lib/rb/review.sh" > "$T/lens-vars.sh"
grep '^QA_PROMPT_FOR() ' "$DIR/bin/lib/rb/pr.sh" > "$T/qa-fn.sh"
for f in plan-block exec-block review-block lens-vars qa-fn; do
  [ -s "$T/$f.sh" ] && ok || bad "setup: could not extract $f from the current scripts"
done

# The common environment for one render: distinct values for every SP_VARS
# name (GATES_NOTE carries text the renderer must never expand), helper stubs
# that print their name and args (so a wrong order fails cmp), and a CC stub
# that writes the prompt ($5) to $CAP.
cat > "$T/env.sh" <<'EOF'
KEY=K-1 TICKET=T-2 PROJECT=demo-x BUILD="$T/build" BRANCH=br-4 BASE=base-5
SPEC_DIR=spec-6 GATES_NOTE='gates ${KEY} $(id) ` %s \n'
CP_PREAMBLE='cp-7 ' UI_PLAN_NOTE='ui-8 ' PLAN_AMBIGUITY_RULE='amb-9'
REPLAN_LINE=' replan-10' REVERT_REASON_LINE='revert-11 ' REOPEN_REASON_LINE='reopen-12 '
KIND_HINT_LINE='kind-13 ' CARRIED_NOTE_LINE='carried-14 ' REPRO_BRIEF_LINE='repro-15 '
CKPT_RESUME_NOTE='ckpt-16 ' KIND_EXEC_NOTE='kexec-17 ' REROUTE_EXEC_NOTE='reroute-18 '
ISSUE_CREATED_AT=2026-01-01 PT_BODY=ptb PT_TITLE=ptt PT_LABELS=ptl NH_SLUG=nhs NH_ISSUE=nhi
PLAN_MODEL=pm EXECUTE_MODEL=em REVIEW_MODEL=rm FIX_MODEL=fm
for _f in th_plan_rule th_fragment_rule ui_notice dup_main_plan_note xrepo_plan_note \
          pfm_plan_rule pt_plan_rule vl_plan_rule nh_prompt_field_note dl_prompt_field_note \
          nh_prompt_release_note rl_prompt_note; do
  eval "$_f() { printf '<%s:%s>' $_f \"\$*\"; }"
done
CC() { printf '%s' "$5" > "$CAP"; }
RESULT() { printf '%s\n' "$1" >> "$T/result.txt"; }
STAMP() { echo 2026-10-23T00:00:00Z; }
LENS_ART() { echo "$BUILD/$1.md"; }
EOF

# run <old|new> <kind> <capture>: one render in a fresh shell; rc is the shell's.
run() {
  rm -f "$3"
  ( cd "$T/cwd" && env T="$T" HARNESS="$H" CAP="$3" MODE="$1" KIND="$2" LIB="$LIB" FX="$FX" \
      bash -c 'set -uo pipefail
        . "$T/env.sh"
        if [ "$MODE" = new ]; then . "$LIB" || exit 9; fi
        case "$MODE:$KIND" in
          old:plan) . "$FX/old-plan.sh" ;;
          new:plan) . "$T/plan-block.sh" ;;
          old:execute) . "$FX/old-execute.sh" ;;
          new:execute) . "$T/exec-block.sh" ;;
          old:review) . "$FX/old-review.sh"; printf "%s" "$REVIEW_PROMPT" > "$CAP" ;;
          new:review) . "$T/review-block.sh"; printf "%s" "$REVIEW_PROMPT" > "$CAP" ;;
          old:fix-round) . "$FX/old-fix-round.sh"; printf "%s" "$L_FIX" > "$CAP" ;;
          new:fix-round) . "$T/review-block.sh"; . "$T/lens-vars.sh"; LENS_VARS review; printf "%s" "$L_FIX" > "$CAP" ;;
          old:qa) . "$FX/old-qa.sh"; QA_PROMPT_FOR https://p.example.invalid > "$CAP" ;;
          new:qa) . "$T/qa-fn.sh"; QA_PROMPT_FOR https://p.example.invalid > "$CAP" ;;
        esac
        printf "%s" "${SP_SOURCE_plan:-}${SP_SOURCE_execute:-}${SP_SOURCE_review:-}" > "$CAP.src"' ) \
    > "$T/run.out" 2>&1
}

byte_equal() { # byte_equal <kind>
  local k=$1
  run old "$k" "$T/old-$k.txt"; run new "$k" "$T/new-$k.txt"
  if [ -s "$T/old-$k.txt" ] && cmp -s "$T/old-$k.txt" "$T/new-$k.txt"; then
    ok; casepass "byte-equal-$k"
  else
    bad "byte-equal-$k: the new render differs from the old builder ($(cmp "$T/old-$k.txt" "$T/new-$k.txt" 2>&1 | head -1); run: $(head -c 300 "$T/run.out"))"
  fi
}

# 1. byte-equal-plan, and SP_SOURCE_plan names the repo template.
byte_equal plan
case "$(cat "$T/new-plan.txt.src" 2>/dev/null)" in
  */prompts/stages/plan.md) ok ;;
  *) bad "byte-equal-plan: SP_SOURCE_plan is '$(cat "$T/new-plan.txt.src" 2>/dev/null)', not the repo prompts/stages/plan.md" ;;
esac
grep -qF '<size-scope:--rules>' "$T/new-plan.txt" && grep -qF '<pt_plan_rule:ptb ptt ptl>' "$T/new-plan.txt" \
  && ok || bad "byte-equal-plan: the stubbed helpers did not reach the prompt (the comparison would be vacuous)"

# 2. mutation-plan: one byte changed in plan.md turns the comparison red.
mkdir -p "$T/mut"; cp "$DIR"/prompts/stages/*.md "$T/mut/" 2>/dev/null
sed -i '0,/PLAN ONLY/s//PLAN 0NLY/' "$T/mut/plan.md" 2>/dev/null
( export SP_STAGES_DIR="$T/mut"; run new plan "$T/mut-plan.txt" )
if [ -s "$T/mut-plan.txt" ] && ! cmp -s "$T/old-plan.txt" "$T/mut-plan.txt"; then ok; casepass mutation-plan
else bad "mutation-plan: a changed plan.md must make the render differ from the old builder"; fi

# 3-6. the other four kinds.
byte_equal execute
grep -qF "$T/build/plan.md" "$T/new-execute.txt" && grep -qF '$BUILD/validate.txt' "$T/new-execute.txt" \
  && ok || bad "byte-equal-execute: the literal \$BUILD/validate.txt must stay literal next to the expanded build path"
byte_equal review
grep -qF 'gates ${KEY} $(id) ` %s \n' "$T/new-review.txt" \
  && ok || bad "byte-equal-review: GATES_NOTE must reach the prompt verbatim"
byte_equal fix-round
byte_equal qa

# 7. render-whitelist: only ${NAME} for a listed NAME is replaced.
mkdir -p "$T/wl"
printf '%s' '${KEY}|${HARNESS_SECRET}|${PATH}|$KEY|${KEY:-x}|${KEY|${ KEY}|${1}|$${KEY}|${REPRO_BRIEF_LINE}' > "$T/wl/plan.md"
WL=$( cd "$T" && env -u REPRO_BRIEF_LINE HARNESS="$H" PROJECT=demo-x KEY=K-1 HARNESS_SECRET=s3cret SP_STAGES_DIR="$T/wl" \
      bash -c 'set -uo pipefail; . "$1" || exit 9; sp_render plan V || exit 8; printf "%s" "$V"' _ "$LIB"; echo "rc=$?")
EXP='K-1|${HARNESS_SECRET}|${PATH}|$KEY|${KEY:-x}|${KEY|${ KEY}|${1}|$K-1|rc=0'
if [ "$WL" = "$EXP" ] && [[ $WL != *s3cret* ]]; then ok; casepass render-whitelist
else bad "render-whitelist: got '$WL', want '$EXP'"; fi

# 8. no-eval: a value is inserted verbatim and never expanded or run.
printf '%s' 'a${KEY}b${PROJECT}' > "$T/wl/execute.md"
VAL="\$(touch $T/pwned) \${PROJECT} \`touch $T/pwned2\` %s"
NE=$( cd "$T" && env HARNESS="$H" PROJECT=p KEY="$VAL" SP_STAGES_DIR="$T/wl" \
      bash -c 'set -uo pipefail; . "$1" || exit 9; sp_render execute' _ "$LIB")
if [ "$NE" = "a${VAL}bp" ] && [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ] && [ "$(grep -cw eval "$LIB" 2>/dev/null)" = 0 ]; then
  ok; casepass no-eval
else bad "no-eval: got '$NE' (pwned: $([ -e "$T/pwned" ] && echo yes || echo no); eval count: $(grep -cw eval "$LIB" 2>/dev/null))"; fi

# sp <dir> <kind> [env...]: render <kind> from <dir> into $T/sp.out (bytes kept).
sp() {
  local d=$1 k=$2; shift 2
  rm -f "$T/sp.out" "$T/sp.src"
  ( cd "$T" && env HARNESS="$H" PROJECT=demo-x KEY=K-1 SP_STAGES_DIR="$d" "$@" T="$T" K="$k" LIB="$LIB" \
      bash -c 'set -uo pipefail; . "$LIB" || exit 9; unset V; sp_render "$K" V; rc=$?
               [ -n "${V+x}" ] && printf "%s" "$V" > "$T/sp.out"
               v="SP_SOURCE_${K//-/_}"; [ -n "${!v+x}" ] && printf "%s" "${!v}" > "$T/sp.src"
               exit $rc' )
}

# 9. no-trailing-newline: the bytes at the end of the file are kept as they are.
mkdir -p "$T/nl"
printf '%s' 'a${KEY}' > "$T/nl/plan.md"; sp "$T/nl" plan
NL1=$(od -An -c "$T/sp.out" | tr -s ' ' | tr -d '\n')
printf 'a\n' > "$T/nl/plan.md"; sp "$T/nl" plan; NL2o=$(od -An -c "$T/sp.out"); grep -q '\\n' <<<"$NL2o" && NL2=y || NL2=n
printf 'x\r\ny${KEY}\r\n' > "$T/nl/plan.md"; sp "$T/nl" plan
printf 'x\r\nyK-1\r\n' > "$T/nl/want"
if [ "$NL1" = " a K - 1" ] && [ "$NL2" = y ] && cmp -s "$T/sp.out" "$T/nl/want"; then ok; casepass no-trailing-newline
else bad "no-trailing-newline: no-newline='$NL1' newline=$NL2 crlf=$(cmp "$T/sp.out" "$T/nl/want" 2>&1)"; fi

# 10. missing-template-refuses: rc 1, nothing assigned; a bad kind is rc 2.
sp "$T/empty" plan; RC=$?
if [ "$RC" = 1 ] && [ ! -e "$T/sp.out" ] && [ ! -e "$T/sp.src" ]; then ok
else bad "missing-template-refuses: rc=$RC out=$([ -e "$T/sp.out" ] && echo set) src=$([ -e "$T/sp.src" ] && echo set)"; fi
sp "$DIR/prompts/stages" security; RC=$?
[ "$RC" = 2 ] && [ ! -e "$T/sp.out" ] && { ok; casepass missing-template-refuses; } \
  || bad "missing-template-refuses: an unknown kind must be rc 2 (got $RC)"

# 11. missing-template-refuses-stage: the plan, execute and review blocks stop
#     the stage with BUILD_REFUSED and make no CC call.
for k in plan execute review; do
  rm -f "$T/result.txt"
  ( export SP_STAGES_DIR="$T/empty"; run new "$k" "$T/refuse-$k.txt" ); RC=$?
  # run() always writes the review/fix-round capture after the block, so for
  # review the proof is the RESULT line and the rc, not the capture file.
  if [ "$RC" = 3 ] && grep -qxF "BUILD_REFUSED prompt template missing ($k)" "$T/result.txt" 2>/dev/null \
     && { [ "$k" = review ] || [ ! -e "$T/refuse-$k.txt" ]; }; then ok
  else bad "missing-template-refuses-stage ($k): rc=$RC result='$(cat "$T/result.txt" 2>/dev/null)' cc=$([ -e "$T/refuse-$k.txt" ] && echo called || echo none)"; fi
done
# fix-round: review.md is there, fix-round.md is not.
mkdir -p "$T/only-review"; cp "$DIR/prompts/stages/review.md" "$T/only-review/" 2>/dev/null
rm -f "$T/result.txt"
( export SP_STAGES_DIR="$T/only-review"; run new review "$T/refuse-fr.txt" ); RC=$?
if [ "$RC" = 3 ] && grep -qxF "BUILD_REFUSED prompt template missing (fix-round)" "$T/result.txt" 2>/dev/null; then ok
else bad "missing-template-refuses-stage (fix-round): rc=$RC result='$(cat "$T/result.txt" 2>/dev/null)'"; fi
grep -q 'BUILD_REFUSED prompt template missing (plan)' "$T/build/pipeline.log" 2>/dev/null \
  && { ok; casepass missing-template-refuses-stage; } \
  || bad "missing-template-refuses-stage: the refusal must be in pipeline.log"

# 12. qa-refuses-no-empty-prompt: the preview-QA region of pr.sh, with the
#     wait-preview stub answering rc 0. Control first (templates present: CC qa
#     runs with the QA prompt), then the refusal (empty dir: no CC qa at all).
awk '/^if \[ -n "\$PR_URL" \] && grep -qiE/{f=1} /^STAGE_END qa /{exit} f' "$DIR/bin/lib/rb/pr.sh" > "$T/qa-region.sh"
grep -q 'CC qa ' "$T/qa-region.sh" && ok || bad "qa-refuses-no-empty-prompt: could not extract the preview-QA region"
mkdir -p "$H/bin"; printf '#!/bin/sh\necho https://p.example.invalid\n' > "$H/bin/wait-preview.sh"; chmod +x "$H/bin/wait-preview.sh"
qa_region() { # qa_region <stages dir> -> $T/qa/{cc.log,tier,qa.md,alerts}
  rm -rf "$T/qa"; mkdir -p "$T/qa/build"
  ( cd "$T/cwd" && env T="$T" HARNESS="$H" LIB="$LIB" SP_STAGES_DIR="$1" bash -c 'set -uo pipefail
      . "$T/env.sh"; . "$LIB" || exit 9
      BUILD="$T/qa/build" ALERTS="$T/qa/alerts" PR_URL=https://github.invalid/pr/1 TIER=1 QA_MODEL=qm SLUG=o/r
      git() { case "$1" in diff) echo app/page.tsx ;; rev-parse|merge-base) echo abc123 ;; esac; }
      gh() { :; }; BB() { :; }; GH_LIVE() { :; }; RB_PUSH() { :; }; track_pushed() { :; }
      # BH-8150 (main): the region records its GitHub writes on the PR record;
      # PRR_SLUG/PRR_NUM are set above the region in pr.sh.
      PRR_SLUG=o/r PRR_NUM=1; prr_write() { :; }; prr_note_push() { :; }; prr_now() { echo 2026-10-23T00:00:00Z; }
      CC() { printf "%s %s\n" "$1" "${#5}" >> "$T/qa/cc.log"; [ "$1" = qa ] && printf "QA: PASS\n" >> "$BUILD/qa.md"; }
      . "$T/qa-fn.sh"; QA_PROMPT_MODE() { QA_PROMPT_FOR "$1"; }
      . "$T/qa-region.sh"
      echo "$TIER" > "$T/qa/tier"; cp "$BUILD/qa.md" "$T/qa/qa.md" 2>/dev/null; true' ) > "$T/qa.out" 2>&1
}
qa_region "$DIR/prompts/stages"
if grep -q '^qa [1-9][0-9]*$' "$T/qa/cc.log" 2>/dev/null && [ "$(cat "$T/qa/tier")" = 1 ]; then ok
else bad "qa-refuses-no-empty-prompt (control): with the templates CC qa must run with a non-empty prompt (cc: $(cat "$T/qa/cc.log" 2>/dev/null); out: $(head -c 300 "$T/qa.out"))"; fi
qa_region "$T/empty"
if [ ! -e "$T/qa/cc.log" ] && [ "$(tail -1 "$T/qa/qa.md" 2>/dev/null)" = 'QA: FAIL' ] \
   && grep -qF 'screens=0' "$T/qa/qa.md" && [ "$(cat "$T/qa/tier" 2>/dev/null)" = 2 ] \
   && [ "$(grep -c 'BUILD_REFUSED prompt template missing (qa)' "$T/qa/alerts" 2>/dev/null)" = 1 ]; then
  ok; casepass qa-refuses-no-empty-prompt
else bad "qa-refuses-no-empty-prompt: cc=$(cat "$T/qa/cc.log" 2>/dev/null | tr '\n' ' ') tier=$(cat "$T/qa/tier" 2>/dev/null) qa.md='$(tail -3 "$T/qa/qa.md" 2>/dev/null)' alerts='$(cat "$T/qa/alerts" 2>/dev/null)' out: $(head -c 300 "$T/qa.out")"; fi

# 13. resolved-wins: a non-empty resolved file wins, byte for byte.
mkdir -p "$H/state/prompts/demo-x"
printf 'R ${KEY}\r\n' > "$H/state/prompts/demo-x/plan.md"; sp "$DIR/prompts/stages" plan
printf 'R K-1\r\n' > "$T/want13"
R1=$( cmp -s "$T/sp.out" "$T/want13" && [ "$(cat "$T/sp.src")" = "$H/state/prompts/demo-x/plan.md" ] && echo y)
printf 'F ${BRANCH}' > "$H/state/prompts/demo-x/fix-round.md"; sp "$DIR/prompts/stages" fix-round BRANCH=b-1
R2=$( [ "$(cat "$T/sp.out")" = 'F b-1' ] && [ "$(cat "$T/sp.src")" = "$H/state/prompts/demo-x/fix-round.md" ] && echo y)
printf ' ' > "$H/state/prompts/demo-x/plan.md"; sp "$DIR/prompts/stages" plan
R3=$( [ "$(cat "$T/sp.out")" = ' ' ] && echo y)
if [ "$R1$R2$R3" = yyy ]; then ok; casepass resolved-wins
else bad "resolved-wins: crlf=$R1 fix-round=$R2 one-space=$R3"; fi
rm -f "$H/state/prompts/demo-x/plan.md" "$H/state/prompts/demo-x/fix-round.md"

# 14. absent-falls-back: no resolved file (and PROJECT empty) renders the repo file.
printf 'repo ${KEY}' > "$T/nl/plan.md"
sp "$T/nl" plan; A1=$(cat "$T/sp.out"); S1=$(cat "$T/sp.src")
sp "$T/nl" plan PROJECT=; A2=$(cat "$T/sp.out"); S2=$(cat "$T/sp.src")
if [ "$A1" = 'repo K-1' ] && [ "$A2" = 'repo K-1' ] && [ "$S1" = "$T/nl/plan.md" ] && [ "$S2" = "$T/nl/plan.md" ]; then ok; casepass absent-falls-back
else bad "absent-falls-back: '$A1' '$A2' src '$S1' '$S2'"; fi

# 15. empty-falls-back: a 0-byte resolved file is ignored.
: > "$H/state/prompts/demo-x/plan.md"; sp "$T/nl" plan
if [ "$(cat "$T/sp.out")" = 'repo K-1' ] && [ "$(cat "$T/sp.src")" = "$T/nl/plan.md" ]; then ok; casepass empty-falls-back
else bad "empty-falls-back: '$(cat "$T/sp.out")' src '$(cat "$T/sp.src")'"; fi
rm -f "$H/state/prompts/demo-x/plan.md"

# 16. rules-pointer-present: line 1 is the pointer; the rest is the plain render.
printf 'rules\n' > "$H/state/prompts/demo-x/rules.md"; sp "$T/nl" plan
printf 'PROJECT RULES OVERRIDE: read %s; it replaces ~/.claude/CLAUDE.md for this build.\nrepo K-1' "$H/state/prompts/demo-x/rules.md" > "$T/want16"
cmp -s "$T/sp.out" "$T/want16" && { ok; casepass rules-pointer-present; } \
  || bad "rules-pointer-present: got '$(cat "$T/sp.out")'"

# 17. rules-pointer-absent: no file, an empty file, another project's file.
rm -f "$H/state/prompts/demo-x/rules.md"; sp "$T/nl" plan; P1=$(cat "$T/sp.out")
: > "$H/state/prompts/demo-x/rules.md"; sp "$T/nl" plan; P2=$(cat "$T/sp.out")
rm -f "$H/state/prompts/demo-x/rules.md"; mkdir -p "$H/state/prompts/other"; printf 'r\n' > "$H/state/prompts/other/rules.md"
sp "$T/nl" plan; P3=$(cat "$T/sp.out")
if [ "$P1|$P2|$P3" = 'repo K-1|repo K-1|repo K-1' ]; then ok; casepass rules-pointer-absent
else bad "rules-pointer-absent: '$P1' '$P2' '$P3'"; fi

# 18. fixture-provenance: each fixture body is the named range of the commit
# its header names (c73cc1b2 for the original capture; a later ticket that
# edits a template on purpose re-captures that fixture from a newer commit).
prov_ok=y; prov_n=0
for f in "$FX"/old-*.sh; do
  spec=$(sed -n '1s/.*from \([0-9a-f]\{7,40\}\):\([^ ]*\) line(s) \([0-9,]*\)\.$/\1 \2 \3/p' "$f")
  [ -n "$spec" ] || { bad "fixture-provenance: $f names no sha range"; prov_ok=n; continue; }
  set -- $spec
  if ! git -C "$DIR" cat-file -e "$1^{commit}" 2>/dev/null; then
    echo "SKIP fixture-provenance: $1 not in this clone ($f)"; continue
  fi
  prov_n=$((prov_n + 1))
  if ! cmp -s <(tail -n +4 "$f") <(git -C "$DIR" show "$1:$2" | sed -n "$3p"); then
    bad "fixture-provenance: $f differs from $1:$2 lines $3"; prov_ok=n
  fi
done
[ "$prov_ok" = y ] && [ "$prov_n" -gt 0 ] && { ok; casepass fixture-provenance; }

# 19. block-order: sp_render plan runs after the BH-7325 migration-number block,
#     and the one CC plan line still follows it.
P="$DIR/bin/lib/rb/plan.sh"
L_SP=$(grep -n '^sp_render plan ' "$P" | head -1 | cut -d: -f1)
L_MN=$(grep -n '^# <<< migration number note (BH-7325)' "$P" | head -1 | cut -d: -f1)
L_CC=$(grep -n '^CC plan "\$PLAN_MODEL" 1200 ' "$P" | cut -d: -f1)
if [ -n "$L_SP" ] && [ -n "$L_MN" ] && [ "$L_SP" -gt "$L_MN" ] && [ "$(grep -c '^CC plan "\$PLAN_MODEL" 1200 ' "$P")" = 1 ] && [ "$L_CC" -gt "$L_SP" ]; then
  ok; casepass block-order
else bad "block-order: sp_render plan at '$L_SP', migration block end at '$L_MN', CC plan at '$L_CC'"; fi

# 20. review-others-inline: the T0 prefix and the security and refute prompts stay in review.sh.
R="$DIR/bin/lib/rb/review.sh"
if grep -q '^SECURITY_PROMPT=' "$R" && grep -q '^REFUTE_PROMPT=' "$R" && grep -qF 'STATIC REVIEW, NO BUILD RUN' "$R" \
   && [ "$(cd "$DIR/prompts/stages" 2>/dev/null && ls | sort | tr '\n' ' ')" = 'execute.md fix-round.md plan.md qa.md review.md ' ]; then
  ok; casepass review-others-inline
else bad "review-others-inline: prompts/stages holds '$(ls "$DIR/prompts/stages" 2>/dev/null | tr '\n' ' ')'"; fi

# 21. resolver-reads-template: bin/prompt-resolve.sh prints the repo template.
JOBS_URL='' HARNESS="$H" "$DIR/bin/prompt-resolve.sh" demo-x plan > "$T/resolve.out" 2>"$T/resolve.err"; RC=$?
if [ "$RC" = 0 ] && cmp -s "$T/resolve.out" "$DIR/prompts/stages/plan.md"; then ok; casepass resolver-reads-template
else bad "resolver-reads-template: rc=$RC $(head -c 200 "$T/resolve.err")"; fi

echo "stage-prompt.bh-7970: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

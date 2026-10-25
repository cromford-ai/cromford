#!/bin/bash
# tests/iron-law-performance.bh-6946-test.sh — BH-6946: every harness prompt
# and rules file that carries the iron-law list carries the performance-by-
# default law too, as literal text.
#
# WHY. the operator's rule (2026-10-15) lives in his own ~/.claude/CLAUDE.md, which
# binds only his Mac. Fleet builds and reviews read rules/CLAUDE.md (rendered
# from rules/topics/) and the prompts in bin/ and prompts/.
#
#   L1  discovery: every tracked file in bin/ prompts/ rules/ (and CLAUDE.md)
#       whose non-comment text names "iron law" and additive-only schema
#       carries the law; discovery finds at least the 7 known carriers
#   L2  the plan text P and the review text R verbatim in the stage, review
#       and lead prompts; P in the design-proposal prompt
#   L3  the security lens (SECURITY_PROMPT) carries the client-snapshot clause S
#   L4  rules/CLAUDE.md carries P and R; bin/render-rules.sh --check is clean
#   L5  the real general-review and security prompt lines, expanded by bash
#       with stub variables, still carry R and S (no $, quote or backtick in
#       the inserted text broke the string)
#   L6  mutation: a copy of the tree with R cut from bin/review-prs.sh is named
#       by the same check, and only that file
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/iron-law-performance.bh-6946-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

P='PERFORMANCE BY DEFAULT (BH-6946): a plan for a screen or loader lists its reads, which of them run in parallel, the expected statement count, the indexes they use, and the loading skeleton.'
R='PERFORMANCE BY DEFAULT (BH-6946), each one a [NOTE] (a BLOCK only on a measured regression on a key screen over the REVIEW LEVELS thresholds, or on a perf ticket): a new sequential await over independent reads; a list read in a layout where a count would do; a route without loading.tsx; a repeated config read without a request memo; a list query without a matching index at seeded volume; unbounded rows to the client; a speed claim without before and after numbers; a client snapshot that holds a token, is not keyed by user and company, or survives sign-out; a key screen with two or more independent requests in sequence before its first content.'
S='a client snapshot (localStorage, sessionStorage, IndexedDB, a persisted store) that holds a token, is not keyed by user and company, or survives sign-out'

# has_perf_law <file> — the law's name and at least one of its two key clauses.
has_perf_law() {
  grep -qiF 'performance by default' "$1" \
    && grep -qiE 'sequential await over independent reads|expected statement count' "$1"
}
# carriers <root> — tracked files whose non-comment text carries the iron-law list
# (the same discovery as tests/iron-law-index-retention.bh-6730-test.sh).
carriers() {
  local f body
  while IFS= read -r f; do
    [ -f "$1/$f" ] || continue
    case "$f" in
      *.md) body=$(cat "$1/$f") ;;
      *) body=$(grep -vE '^[[:space:]]*(#|//)' "$1/$f") ;;
    esac
    grep -qiE 'iron law' <<<"$body" && grep -qiE 'additive[- ]only' <<<"$body" && printf '%s\n' "$f"
  done < <(git -C "$1" ls-files -- bin prompts rules CLAUDE.md)
}

# ── L1 every carrier ──────────────────────────────────────────────────────────
mapfile -t C < <(carriers "$DIR")
# TEST-CHANGE (BH-7970): the general review lens text moved from bin/lib/rb/review.sh to prompts/stages/review.md.
for want in rules/CLAUDE.md rules/topics/04-building-software.md bin/review-prs.sh bin/review-autopilot.sh \
            prompts/stages/review.md prompts/project-6.md bin/draft-proposal.sh; do
  grep -qx "$want" < <(printf '%s\n' "${C[@]}") && ok || bad "L1 discovery did not find the known carrier $want (found: ${C[*]})"
done
for f in "${C[@]}"; do
  has_perf_law "$DIR/$f" && ok || bad "L1 $f carries the iron-law list but not the performance law"
done

# ── L2 the literal texts in the stage, review and lead prompts ───────────────
# TEST-CHANGE (BH-7970): the plan and execute prompt texts moved from bin/lib/rb/{plan,execute}.sh to prompts/stages/{plan,execute}.md.
for f in prompts/stages/plan.md bin/run-preplan.sh prompts/stages/execute.md prompts/project-6.md; do
  grep -qF -- "$P" "$DIR/$f" && ok || bad "L2 $f lacks the plan text P"
  grep -qF -- "$R" "$DIR/$f" && ok || bad "L2 $f lacks the review text R"
done
# TEST-CHANGE (BH-7970): the general review lens text moved from bin/lib/rb/review.sh to prompts/stages/review.md.
for f in prompts/stages/review.md bin/review-prs.sh bin/review-autopilot.sh prompts/lead-review.md prompts/lead-review-builds-on.md; do
  grep -qF -- "$R" "$DIR/$f" && ok || bad "L2 $f lacks the review text R"
done
grep -qF -- "$P" "$DIR/bin/draft-proposal.sh" && ok || bad "L2 bin/draft-proposal.sh lacks the plan text P"

# ── L3 the security lens ──────────────────────────────────────────────────────
grep -E '^SECURITY_PROMPT=' "$DIR/bin/lib/rb/review.sh" | grep -qF -- "$S" && ok || bad "L3 SECURITY_PROMPT lacks the client-snapshot clause S"

# ── L4 the fleet rules ────────────────────────────────────────────────────────
grep -qF -- "$P" "$DIR/rules/CLAUDE.md" && ok || bad "L4 rules/CLAUDE.md lacks P"
grep -qF -- "$R" "$DIR/rules/CLAUDE.md" && ok || bad "L4 rules/CLAUDE.md lacks R"
grep -qF -- "$P" "$DIR/rules/topics/04-building-software.md" && ok || bad "L4 rules/topics/04-building-software.md lacks P"
"$DIR/bin/render-rules.sh" --root "$DIR" --check >/dev/null 2>&1 && ok || bad "L4 bin/render-rules.sh --check: rules/CLAUDE.md is not the render of rules/topics/"

# ── L5 the real prompt lines, expanded by bash ───────────────────────────────
# Each line is copied from the real file into a script with stub variables and
# run, so bash itself expands the double-quoted string the review lane sends.
# TEST-CHANGE (BH-7970): the general-review line moved to prompts/stages/review.md,
# a ${NAME} template. It is expanded by the real renderer, sp_render, instead of
# by a bash double-quoted string; the assertions are the same.
gen=$(grep -E '^Adversarially review the diff of branch' "$DIR/prompts/stages/review.md")
sec=$(grep -E '^SECURITY_PROMPT=' "$DIR/bin/lib/rb/review.sh")
if [ -n "$gen" ]; then
  mkdir -p "$T/stages"; printf '%s' "$gen" > "$T/stages/review.md"
  out=$(HARNESS="$T/no-harness" PROJECT=p BRANCH=b BASE=main KEY=X-1 BUILD=/tmp SP_STAGES_DIR="$T/stages" \
        bash -c 'set -u; . "$1" && sp_render review' _ "$DIR/bin/lib/stage-prompt.sh" 2>"$T/gen.err"); rc=$?
  [ "$rc" = 0 ] && ok || bad "L5 the general-review line did not expand (rc $rc: $(head -c 200 "$T/gen.err"))"
  grep -qF -- "$R" <<<"$out" && ok || bad "L5 the expanded general-review prompt lacks R"
  grep -qF -- 'branch b against main' <<<"$out" && ok || bad "L5 the stub variables did not expand in the general-review prompt"
else
  bad "L5 no general-review prompt line in prompts/stages/review.md"
fi
if [ -n "$sec" ]; then
  { printf 'BRANCH=b BASE=main KEY=X-1 BUILD=/tmp\n'; printf '%s\n' "$sec"; printf 'printf %%s "$SECURITY_PROMPT"\n'; } > "$T/sec.sh"
  out=$(bash "$T/sec.sh" 2>"$T/sec.err"); rc=$?
  [ "$rc" = 0 ] && ok || bad "L5 SECURITY_PROMPT did not expand (rc $rc: $(head -c 200 "$T/sec.err"))"
  grep -qF -- "$S" <<<"$out" && ok || bad "L5 the expanded SECURITY_PROMPT lacks S"
  grep -qF -- '/tmp/security-review.md' <<<"$out" && ok || bad "L5 the stub variables did not expand in SECURITY_PROMPT"
else
  bad "L5 no SECURITY_PROMPT= line in bin/lib/rb/review.sh"
fi

# ── L6 the check can fail ─────────────────────────────────────────────────────
M="$T/mut"; mkdir -p "$M"
git -C "$DIR" ls-files -- bin prompts rules CLAUDE.md | while IFS= read -r f; do
  mkdir -p "$M/$(dirname "$f")"; cp "$DIR/$f" "$M/$f"
done
git -C "$M" init -q; git -C "$M" add -A
sed -i.bak 's/sequential await over independent reads/sequential reads/' "$M/bin/review-prs.sh"; rm -f "$M/bin/review-prs.sh.bak"
cmp -s "$M/bin/review-prs.sh" "$DIR/bin/review-prs.sh" && bad "L6 the mutation did not change bin/review-prs.sh"
miss=""; while IFS= read -r f; do has_perf_law "$M/$f" || miss="$miss $f"; done < <(carriers "$M")
[ "$miss" = " bin/review-prs.sh" ] && ok || bad "L6 the check must name exactly bin/review-prs.sh (got:$miss)"

echo "iron-law-performance.bh-6946: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

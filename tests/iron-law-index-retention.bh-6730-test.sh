#!/bin/bash
# tests/iron-law-index-retention.bh-6730-test.sh — BH-6730: every harness prompt
# and rules file that carries the iron-law list carries the indexes-and-
# retention law too.
#
# WHY. the operator's rule (2026-10-14) lives in his own ~/.claude/CLAUDE.md, which
# binds only his Mac. Fleet builds and reviews read rules/CLAUDE.md (rendered
# from rules/topics/), the repo CLAUDE.md and the prompts in bin/ and prompts/.
#
#   L1  discovery: every tracked file in bin/ prompts/ rules/ (and CLAUDE.md)
#       whose non-comment text names "iron law" and additive-only schema
#       carries the law; discovery finds at least the 7 known carriers
#   L2  the stage and lead prompts that point at the laws without the list
#       carry it: rb/plan.sh, run-preplan.sh, rb/execute.sh, lead-review.md,
#       lead-review-builds-on.md, the lead checklist (item 15, v8), CLAUDE.md
#   L3  rules/CLAUDE.md carries the ticket's five rule lines verbatim, and
#       bin/render-rules.sh --check is clean (edited in rules/topics/)
#   L4  mutation: a copy of the tree with the law cut from prompts/stages/review.md
#       is named by the same check
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/iron-law-index-retention.bh-6730-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# has_law <file> — the law's two halves: the index rule and the retention rule.
has_law() {
  grep -qiE 'indexes for every query on a new table|ships with the indexes its queries need|new table or query (without its|with no) index' "$1" \
    && grep -qiE 'retention rule' "$1"
}
# carriers <root> — tracked files whose non-comment text carries the iron-law list.
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
  has_law "$DIR/$f" && ok || bad "L1 $f carries the iron-law list but not the index/retention law"
done

# ── L2 the stage and lead prompts ─────────────────────────────────────────────
# TEST-CHANGE (BH-7970): the plan and execute prompt texts moved from bin/lib/rb/{plan,execute}.sh to prompts/stages/{plan,execute}.md.
for f in prompts/stages/plan.md bin/run-preplan.sh prompts/stages/execute.md prompts/lead-review.md prompts/lead-review-builds-on.md \
         prompts/lead-review-checklist.md CLAUDE.md; do
  has_law "$DIR/$f" && ok || bad "L2 $f does not carry the index/retention law"
done
grep -q 'per-row correlated subquery' "$DIR/prompts/lead-review.md" && ok || bad "L2 lead-review.md item 2 does not name the correlated subquery"
# TEST-CHANGE (BH-8029): the checklist moved to version 10; this case checks version 9 or later.
ckv=$(head -1 "$DIR/prompts/lead-review-checklist.md" | sed -n 's/^Checklist-Version: \([0-9][0-9]*\)$/\1/p')
[ -n "$ckv" ] && [ "$ckv" -ge 9 ] && ok || bad "L2 the lead checklist is not version 9 or later"
grep -qE '^15\. Indexes and retention \(BH-6730\)' "$DIR/prompts/lead-review-checklist.md" && ok || bad "L2 the lead checklist has no item 15"

# ── L3 the rule text, self-contained ──────────────────────────────────────────
for line in \
  'Every new table ships with the indexes its queries need, in the same migration: name the index that serves each WHERE, JOIN, ORDER BY and GROUP BY.' \
  'A later index goes in a new additive migration (`CREATE INDEX IF NOT EXISTS`).' \
  'No correlated subquery that re-runs per row over a large table. A poll or dashboard that recomputes an aggregate over all history gets a summary table or a short cache.' \
  'Every growing table has a retention rule: what the rows are for, how long they keep value, and a scheduled job that deletes or archives the rest (window in a settings row, dry-run first, one audit row per run). Money and history rows are archived, never silently deleted.' \
  'Reviews BLOCK on a new per-row correlated subquery over a large table; a missing index or retention rule is a review note that names the fix (BH-7123).'; do
  grep -qF -- "$line" "$DIR/rules/CLAUDE.md" && ok || bad "L3 rules/CLAUDE.md lacks: ${line:0:70}"
  grep -qF -- "$line" "$DIR/CLAUDE.md" && ok || bad "L3 CLAUDE.md lacks: ${line:0:70}"
done
"$DIR/bin/render-rules.sh" --root "$DIR" --check >/dev/null 2>&1 && ok || bad "L3 bin/render-rules.sh --check: rules/CLAUDE.md is not the render of rules/topics/"

# ── L4 the check can fail ─────────────────────────────────────────────────────
M="$T/mut"; mkdir -p "$M"
git -C "$DIR" ls-files -- bin prompts rules CLAUDE.md | while IFS= read -r f; do
  mkdir -p "$M/$(dirname "$f")"; cp "$DIR/$f" "$M/$f"
done
git -C "$M" init -q; git -C "$M" add -A
# TEST-CHANGE (BH-7970): the mutated carrier is the scratch copy of prompts/stages/review.md, where the review text now lives.
sed -i.bak 's/indexes for every query on a new table/new tables/' "$M/prompts/stages/review.md"; rm -f "$M/prompts/stages/review.md.bak"
cmp -s "$M/prompts/stages/review.md" "$DIR/prompts/stages/review.md" && bad "L4 the mutation did not change prompts/stages/review.md"
miss=""; while IFS= read -r f; do has_law "$M/$f" || miss="$miss $f"; done < <(carriers "$M")
[ "$miss" = " prompts/stages/review.md" ] && ok || bad "L4 the check must name exactly prompts/stages/review.md (got:$miss)"

echo "iron-law-index-retention.bh-6730: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

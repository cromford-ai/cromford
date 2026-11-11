#!/bin/bash
# tests/rules-fewest-tickets.bh-8739-test.sh — BH-8739: the fewest tickets.
# One ticket per AREA or flow, never per screen. Triage keeps one ticket with a
# checklist. A review files at most one follow-up per area.
#
#   R1  the new heading is in topic 12, the rendered rules/CLAUDE.md (heading
#       and Contents entry) and catalog/prompt-markers.json
#   R2  the old "per screen" phrases are gone from the rules, the stage
#       templates, the review-levels fragment and the five bin prompts
#   R3  the triage bullet is in topic 02 and in rules/CLAUDE.md
#   R4  "per area" in topic 13, the 20261016 fragment and the four stage
#       templates; the plan template carries the SLICE-REASON rule
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/rules-fewest-tickets.bh-8739-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

HEAD='## Findings and splits: the fewest tickets, one per area or flow (the operator, 2026-10-28)'
OLDHEAD='collect first, one ticket per screen or flow'
TRIAGE='Triage never splits a ticket into many. When a ticket holds several asks, keep one ticket and list the asks as a checklist. Ask the requester only when two asks conflict.'
FOLLOW='At most one follow-up ticket per area, never per screen'
GROUPED='ONE follow-up ticket per area or flow'
SLICER="Write the reason on its own line as 'SLICE-REASON: <file-overlap|context-ceiling|ordering>: <why>'. No reason, no slice."

# has <file> <fixed-string> — rc 0 when the file exists and carries the string.
has() { [ -r "$DIR/$1" ] && grep -qF -- "$2" "$DIR/$1"; }

# --- R1: the new heading ---------------------------------------------------------------
for f in rules/topics/12-qa-findings.md rules/CLAUDE.md; do
  grep -qxF -- "$HEAD" "$DIR/$f" 2>/dev/null && ok || bad "R1: $f lacks the heading line '$HEAD'"
done
grep -qF -- '- [Findings and splits: the fewest tickets, one per area or flow (the operator, 2026-10-28)](#findings-and-splits-the-fewest-tickets-one-per-area-or-flow-operator-2026-10-28)' \
  "$DIR/rules/CLAUDE.md" 2>/dev/null && ok || bad "R1: rules/CLAUDE.md Contents lacks the new entry"
jq -e --arg h "$HEAD" '[.. | strings] | index($h) != null' "$DIR/catalog/prompt-markers.json" >/dev/null 2>&1 \
  && ok || bad "R1: catalog/prompt-markers.json does not pin the new heading"
has rules/topics/12-qa-findings.md 'A screen is never the unit.' && ok || bad "R1: topic 12 must say a screen is never the unit"
for w in file-overlap context-ceiling ordering SLICE_CONFIRM_OVER gf_area group_findings_areas bin/lib/slice-gate.sh; do
  has rules/topics/12-qa-findings.md "$w" && ok || bad "R1: topic 12 must name $w"
done

# --- R2: the old phrases are gone ------------------------------------------------------
R2_FILES="rules/CLAUDE.md rules/topics/12-qa-findings.md rules/topics/13-review-levels.md
prompts/iron-laws.d/20261016-review-levels.md prompts/stages/plan.md prompts/stages/execute.md
prompts/stages/qa.md prompts/stages/review.md bin/run-preplan.sh bin/review-prs.sh
bin/lib/rb/review.sh bin/lib/rb/result.sh catalog/prompt-markers.json"
for f in $R2_FILES; do
  [ -r "$DIR/$f" ] || { bad "R2: $f is missing (a missing file is not proof the phrase is gone)"; continue; }
  for p in 'per screen or flow' 'follow-up ticket per screen,' "$OLDHEAD"; do
    grep -qF -- "$p" "$DIR/$f" && bad "R2: $f still carries '$p'" || ok
  done
done
for f in rules/topics/*.md; do
  grep -qF -- 'per screen or flow' "$f" && bad "R2: $f still carries 'per screen or flow'" || ok
done

# --- R3: the triage bullet -------------------------------------------------------------
for f in rules/topics/02-board-triage.md rules/CLAUDE.md; do
  has "$f" "$TRIAGE" && ok || bad "R3: $f lacks the triage bullet"
done

# --- R4: per area in the review rule and the stage templates ---------------------------
for f in rules/topics/13-review-levels.md prompts/iron-laws.d/20261016-review-levels.md rules/CLAUDE.md; do
  has "$f" "$FOLLOW" && ok || bad "R4: $f lacks '$FOLLOW'"
done
for s in plan execute qa review; do
  has "prompts/stages/$s.md" "$GROUPED" && ok || bad "R4: prompts/stages/$s.md lacks '$GROUPED'"
done
for f in bin/run-preplan.sh bin/review-prs.sh bin/lib/rb/review.sh bin/lib/rb/result.sh; do
  has "$f" "$GROUPED" && ok || bad "R4: $f lacks '$GROUPED'"
done
has prompts/stages/plan.md "$SLICER" && ok || bad "R4: prompts/stages/plan.md lacks the SLICE-REASON rule"
has prompts/stages/plan.md 'build-execute context ceiling in catalog/context-budgets.json' \
  && ok || bad "R4: the plan SLICE rule must name the build-execute context ceiling"

# R5 (the decompose prompt names the three reasons and est_lines) is driven,
# not grepped: tests/run-decompose-slice-reasons.bh-8739-test.sh case D13.

echo "rules-fewest-tickets.bh-8739: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

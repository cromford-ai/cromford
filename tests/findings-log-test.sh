#!/bin/bash
# tests/findings-log-test.sh — self-contained assertions for bin/findings-log.sh.
# Run from anywhere: tests/findings-log-test.sh   (exit 0 = all pass)
# No network, no secrets: every input is a fixture under catalog/fixtures/findings/.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
FIX="$DIR/catalog/fixtures/findings"
export HARNESS="$T"
mkdir -p "$T/logs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
FLOG="$T/logs/findings.log"
RUN="$DIR/bin/findings-log.sh"

mkbuild() { # mkbuild <name> [<fixture>:<target> ...]
  local d="$T/builds/$1"; shift
  mkdir -p "$d"
  local p; for p in "$@"; do cp "$FIX/${p%%:*}" "$d/${p##*:}"; done
  echo "$d"
}

# 1. general lens: D-citations, BLOCK verdict, ticket/lens/family annotations
B=$(mkbuild b1 review-block.md:review.md)
"$RUN" "$B" project-2 TK-208 || bad "rc nonzero on happy path"
grep -q 'ticket=TK-208 lens=general verdict=BLOCK rule=D14 family=[0-9a-f]\{12\} :: ' "$FLOG" \
  && ok || bad "general lens D14/BLOCK row (got: $(cat "$FLOG" 2>/dev/null))"
grep -q 'rule=D1 family=' "$FLOG" && ok || bad "D1 citation not extracted"
grep -q 'rule=D25 family=' "$FLOG" && ok || bad "D25 (non-blocking note) not extracted"

# 2. a finding with no D citation still logs, with rule=-
grep -q 'rule=- family=[0-9a-f]\{12\} :: \*\*BLOCKING:\*\* validate.txt' "$FLOG" \
  && ok || bad "uncited finding should log with rule=-"

# 3. section headers are not findings (too short to be a headline)
grep -q ':: Blocking findings' "$FLOG" && bad "section header logged as a finding" || ok

# 4. security lens is labelled security; refuter lens is labelled refuter
B=$(mkbuild b2 security-review-block.md:security-review.md refute-review-approve.md:refute-review.md)
"$RUN" "$B" project-2 TK-209 || bad "rc nonzero on security/refuter"
grep -q 'ticket=TK-209 lens=security verdict=BLOCK .* :: .*ENABLE ROW LEVEL SECURITY' "$FLOG" \
  && ok || bad "security lens row"
grep -q 'ticket=TK-209 lens=refuter verdict=APPROVE ' "$FLOG" \
  && ok || bad "refuter lens row (numbered list findings)"

# 5. dedup: the same finding restated in a re-review appends once, not twice.
#    Verdict is the LAST verdict in the file (the re-review's APPROVE).
B=$(mkbuild b3 review-approve-rerun.md:review.md)
"$RUN" "$B" project-2 TK-211
N=$(grep -c 'ticket=TK-211 ' "$FLOG")
[ "$N" = 1 ] && ok || bad "dedup within one build (got $N rows, want 1)"
grep -q 'ticket=TK-211 lens=general verdict=APPROVE ' "$FLOG" \
  && ok || bad "verdict should be the LAST verdict in the file"

# 6. family key is the shared alert_family key: two findings differing only in
#    numbers/hashes MUST collapse to one family (that is the promotion signal).
B=$(mkbuild b4)
cat > "$B/review.md" <<'EOF'
- **BLOCKING (D9):** the sync route in `src/app/api/sync/route.ts` reports SUCCESS for run 4471 even though 3 of 12 records failed to write.
VERDICT: BLOCK
EOF
"$RUN" "$B" project-3 TK-101
B=$(mkbuild b5)
cat > "$B/review.md" <<'EOF'
- **BLOCKING (D9):** the sync route in `src/app/api/sync/route.ts` reports SUCCESS for run 9902 even though 7 of 84 records failed to write.
VERDICT: BLOCK
EOF
"$RUN" "$B" project-3 TK-102
F1=$(grep 'ticket=TK-101 ' "$FLOG" | sed -n 's/.*family=\([0-9a-f]*\) .*/\1/p')
F2=$(grep 'ticket=TK-102 ' "$FLOG" | sed -n 's/.*family=\([0-9a-f]*\) .*/\1/p')
[ -n "$F1" ] && [ "$F1" = "$F2" ] && ok \
  || bad "family key must ignore digits (got '$F1' vs '$F2')"

# 7. malformed review file: control bytes, no VERDICT line -> rc 0, no crash
BEFORE=$(wc -l < "$FLOG")
B=$(mkbuild b6 review-malformed.md:review.md)
"$RUN" "$B" project-2 TK-212 || bad "rc nonzero on malformed review"
grep -q 'ticket=TK-212 ' "$FLOG" && bad "malformed file produced rows" || ok
[ "$(wc -l < "$FLOG")" = "$BEFORE" ] && ok || bad "malformed file appended lines"

# 8. missing build dir -> rc 0, nothing appended (fail-open: never break a build)
BEFORE=$(wc -l < "$FLOG")
"$RUN" "$T/no-such-build" project-2 TK-213 || bad "rc nonzero on missing dir"
[ "$(wc -l < "$FLOG")" = "$BEFORE" ] && ok || bad "missing dir wrote lines"

# 9. missing args -> rc 0, nothing appended
"$RUN" || bad "rc nonzero with no args"
"$RUN" "$T/builds/b1" || bad "rc nonzero with partial args"
[ "$(wc -l < "$FLOG")" = "$BEFORE" ] && ok || bad "missing args wrote lines"

# 10. cap: 60 findings in one review -> 40 rows
B=$(mkbuild b7)
for i in $(seq 1 60); do
  echo "- **BLOCKING (D3):** assertion number $i in \`tests/suite-$i.test.ts\` pins source text with a regex instead of asserting the rendered value." >> "$B/review.md"
done
echo "VERDICT: BLOCK" >> "$B/review.md"
"$RUN" "$B" project-4 TK-1
N=$(grep -c 'ticket=TK-1 ' "$FLOG")
[ "$N" = 40 ] && ok || bad "cap (got $N rows, want 40)"

# 11. long finding truncated (~330 chars of payload, like decision-log)
B=$(mkbuild b8)
LONG=$(printf 'x%.0s' $(seq 1 900))
printf -- '- **BLOCKING (D11):** %s\nVERDICT: BLOCK\n' "$LONG" > "$B/review.md"
"$RUN" "$B" project-4 TK-2
LEN=$(grep 'ticket=TK-2 ' "$FLOG" | head -1 | wc -c)
[ "$LEN" -lt 520 ] && ok || bad "truncation (line length $LEN)"

# 12. exactly-once: a second call on the same build re-appends nothing.
#     run-build.sh calls this once per lens, and every call sees all three files.
B=$(mkbuild b9 review-block.md:review.md)
"$RUN" "$B" project-2 TK-214
N1=$(grep -c 'ticket=TK-214 ' "$FLOG")
"$RUN" "$B" project-2 TK-214
N2=$(grep -c 'ticket=TK-214 ' "$FLOG")
[ "$N1" -gt 0 ] && [ "$N1" = "$N2" ] && ok \
  || bad "second call must harvest nothing (got $N1 then $N2)"

# 13. ...but a lens that ARRIVES LATER is still harvested by a later call
cp "$FIX/security-review-block.md" "$B/security-review.md"
"$RUN" "$B" project-2 TK-214
grep -q 'ticket=TK-214 lens=security ' "$FLOG" \
  && ok || bad "a lens written after the first call must still be harvested"

# 14. run-build.sh harvests before it adjudicates, on BOTH of its flow paths.
# This used to count three calls, one per lens, because the lenses ran one after
# another. Since 2026-09-12 they run concurrently under LENSES_PARALLEL=1, where
# ONE call harvests every lens (this script is idempotent per lens — assertions
# 12 and 13 above), and the sequential rollback path still calls it once per
# lens from inside its loop. The count was never the property worth pinning; the
# ORDER is, because a build that exits on a BLOCK before harvesting loses
# exactly the findings worth keeping. So: one call per flow path, and no lens
# adjudicated before a harvest.
RBF="$RB_ALL"
awk '/^# >>> review lenses/{f=1} /^# <<< review lenses/{exit} f' "$RBF" > "$T/lens-block.sh"
[ -s "$T/lens-block.sh" ] \
  && ok || bad "could not extract the review-lens block from run-build.sh — markers missing?"
[ "$(grep -c 'findings-log.sh' "$T/lens-block.sh")" = 2 ] \
  && ok || bad "the review-lens block must harvest exactly once per flow path (got $(grep -c 'findings-log.sh' "$T/lens-block.sh"))"
awk '/findings-log.sh/{h=1} /\|\| LENS_REFUSE/{ if (!h) unharvested=1; h=0 } END{ exit unharvested?1:0 }' \
  "$T/lens-block.sh" \
  && ok || bad "a lens is adjudicated before its findings are harvested — a BLOCK would be lost"

# ══ Fraud classes (2026-08-26) ═══════════════════════════════════════════════
# The review lenses now name six fraud classes and tag a finding that is one of
# them. The harvester lifts that tag into an OPTIONAL `fraud=` field. Optional
# is the whole design: an untagged finding's line must stay byte-identical to
# what it was before this field existed, because two other scripts parse these
# lines and a mandatory `fraud=-` on 11K rows would be churn for nothing.

# 15. every tagged class is harvested, and lands between rule= and family=
B=$(mkbuild b10 review-fraud-tagged.md:review.md)
"$RUN" "$B" project-2 TK-301 || bad "rc nonzero on a fraud-tagged review"
for CLASS in weakened-tests false-completion unauthorized-action scope-creep spec-betrayal debris; do
  grep -q "ticket=TK-301 .* fraud=$CLASS family=[0-9a-f]\{12\} :: " "$FLOG" \
    && ok || bad "fraud class $CLASS not harvested (rows: $(grep -c 'ticket=TK-301 ' "$FLOG"))"
done

# 16. FIELD ORDER: family= stays the LAST field before `::`. That adjacency is
#     the documented shape of this line and what every hand-written grep for a
#     family reaches for (the assertions above included), so the new optional
#     field goes ahead of it rather than between family= and the payload. The
#     field-walking consumers do not care either way — proven in
#     rule-miner-findings-test.sh and repeat-family-test.sh — but a log format
#     with one stable anchor is worth more than one without.
grep -q 'fraud=[a-z-]* family=[0-9a-f]\{12\} :: ' "$FLOG" && ok \
  || bad "fraud= must precede family=, keeping 'family=<key> ::' adjacent"
grep -q 'family=[0-9a-f]\{12\} fraud=' "$FLOG" && bad "fraud= landed after family=" || ok

# 17. an UNTAGGED finding keeps the pre-existing line format exactly
grep -q 'ticket=TK-301 .* rule=- family=[0-9a-f]\{12\} :: A plain finding with no fraud tag' "$FLOG" \
  && ok || bad "an untagged finding must carry no fraud= field at all"

# 18. ANTI-INJECTION: reviewers write this text, so only the six known class
#     names become a field. An invented class is prose, not metadata — the row
#     still logs (the finding is real), it just carries no fraud=.
grep -q 'fraud=creative-accounting' "$FLOG" && bad "an unknown fraud class became a field" || ok
grep -q ':: \*\*(FRAUD: creative-accounting)' "$FLOG" && ok \
  || bad "the finding itself must still be logged, tag and all, in the payload"

# 18b. THE CLOSED SET IS A PREFIX TRAP without a full lookahead: `FRAUD:
#      weakened-tests2` would match `weakened-tests` and log a MISLABEL, which
#      is worse than the rejection the closed set exists to produce. Digits and
#      underscore belong in the lookahead alongside letters and the hyphen.
B=$(mkbuild b11)
cat > "$B/review.md" <<'EOF'
- **BLOCKING (D3, FRAUD: weakened-tests2):** a class name that merely starts like a real one, on a finding long enough to be a real headline.
- **BLOCKING (D3, FRAUD: debris_old):** another near-miss class name, on a finding long enough to be a real headline.
VERDICT: BLOCK
EOF
"$RUN" "$B" project-4 TK-3
grep -q 'ticket=TK-3 .* fraud=' "$FLOG" && bad "a near-miss class name was logged as a real fraud class" || ok
[ "$(grep -c 'ticket=TK-3 ' "$FLOG")" = 2 ] && ok || bad "both near-miss findings must still be logged (untagged)"

# 19. the tag survives in the payload for the tagged classes too — the log is
#     evidence, not a summary, and the reviewer's own words are the evidence.
grep -q 'fraud=weakened-tests .*:: .*expect(true)' "$FLOG" && ok \
  || bad "the tagged finding's text must be logged verbatim, not replaced by the class"

# 20. the review prompts actually ask for the tag the harvester looks for.
# Anchored on the three prompt VARIABLES rather than on a phrase inside one of
# them: the refuter's opening sentence became mode-dependent when the lenses
# started running together (it could no longer claim "two reviewers already
# APPROVED" about reviews that had not finished), and a needle in prose pins the
# wording, not the lens. The FRAUD/D-rule assertions below are what actually
# check the content, and they are unchanged.
for LENS in 'REVIEW_PROMPT=' 'SECURITY_PROMPT=' 'REFUTE_PROMPT=' 'SECURITY-ONLY review'; do
  N=$(grep -c "$LENS" "$RB_ALL")
  [ "$N" -ge 1 ] || bad "lens prompt not found in run-build.sh: $LENS"
done
# TEST-CHANGE (BH-7970): the general lens text moved to prompts/stages/review.md; the count spans the pipeline and that file.
N=$(cat "$RB_ALL" "$DIR/prompts/stages/review.md" | grep -c 'FRAUD: <weakened-tests')
[ "$N" = 3 ] && ok || bad "all three review lenses must name the six classes (got $N)"
grep -q 'D1-D34' "$RB_ALL" && ok \
  || bad "the D-rule citation sentence must still be there, widened to D34"

echo "findings-log-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]

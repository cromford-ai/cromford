#!/bin/bash
# tests/coverage-review.bh-9499-test.sh — the in-build general review runs the
# lead-review checklist and answers the plan's `## Requirements coverage` table
# row by row. A row the diff does not deliver, or a row with no COVERAGE-ROW
# line, turns an APPROVE in review.md into a BLOCK before any reader sees the
# verdict, so the fix round runs inside the build.
#
# Driven: bin/lib/coverage-review.sh and bin/lib/coverage-rows.sh as installed by
# scratch_install_closure, the shipped LENS_ART / LENS_APPROVED definitions and
# the `# >>> coverage review (BH-9499)` region of bin/lib/rb/review.sh
# (flattened by rb_all), and bin/findings-log.sh, on the fixtures in
# tests/fixtures/coverage-review.bh-9499/.
#   C1-C3  cr_plan_row_list: the rows cr_plan_rows counts, never header/separator
#   N1-N7  cv_review_note: checklist, numbered rows, NOT IN DIFF hint, caps
#   J1-J10 cv_judge / cv_enforce: the row rule over the latest pass
#   E1-E5  the shipped review.sh blocks (E2 and E5 = the ticket's acceptance)
#   K1-K3  the knobs
#   Z1     no model call
# Mutations checked by hand (D1/D63): drop the cv_enforce call in LENS_APPROVED
# (E2 red), drop the `not traced` reason (J2 red), count fenced rows (J4 red),
# drop the NOT IN DIFF hint (N3 red).
# No network, no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/coverage-review.bh-9499-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
unset PROJECT KEY BUILD
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq missing"; exit 1; }
export VERDICT_WINDOW_LINES=12
FX="$DIR/tests/fixtures/coverage-review.bh-9499"
C0="$DIR/tests/fixtures/coverage-rows.bh-9441"

mkdir -p "$T/h/prompts" "$T/b"
scratch_install_closure bin/lib/coverage-review.sh "$T/h" >/dev/null || bad "closure install of bin/lib/coverage-review.sh"
scratch_install_closure bin/lib/spec-trace.sh "$T/h" >/dev/null || bad "closure install of bin/lib/spec-trace.sh"
scratch_install_closure bin/findings-log.sh "$T/h" >/dev/null || bad "closure install of bin/findings-log.sh"
cp "$DIR/prompts/lead-review-checklist.md" "$T/h/prompts/lead-review-checklist.md"
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^LENS_ART\(\) \{/{f=1} f{print} f && /^LENS_APPROVED\(\) \{/{g=1} g && /^}/{exit}' "$RB_ALL" > "$T/lens.sh"
awk '/^# >>> coverage review \(BH-9499\)/{f=1;next} /^# <<< coverage review \(BH-9499\)/{exit} f' "$RB_ALL" > "$T/note.sh"
grep -q 'cv_enforce' "$T/lens.sh" && ok || bad "LENS_APPROVED must call cv_enforce"
[ -s "$T/note.sh" ] && ok || bad "could not extract the coverage review region of review.sh"

STAMP() { echo TS; }
PROJECT=widget-os KEY=FX-9499 BUILD="$T/b" HARNESS="$T/h"
# shellcheck source=/dev/null
. "$T/h/bin/lib/verdict-parse.sh" 2>/dev/null || bad "verdict-parse.sh in the closure"
# shellcheck source=/dev/null
. "$T/lens.sh"
command -v cv_enforce >/dev/null 2>&1 && ok || bad "the lens region must source bin/lib/coverage-review.sh"
command -v cr_plan_row_list >/dev/null 2>&1 && ok || bad "coverage-review.sh must bring cr_plan_row_list"

cp "$FX/plan.md" "$T/b/plan.md"
cp "$FX/ticket.json" "$T/b/ticket-meta.json"
use() { cp "$FX/$1" "$T/b/review.md"; }
review() { # review <rows...> — a review.md with the rows and an APPROVE
  { printf '# Review (fixture)\n\nThe diff adds the rows screen.\n\n'
    printf '%s\n' "$@"
    printf '\nTIER: 1\nVERDICT: APPROVE\n'; } > "$T/b/review.md"
}
last() { tail -1 "$T/b/review.md"; }
gate() { grep 'COVERAGE-GATE:' "$T/b/review.md"; }
R1='COVERAGE-ROW: R1 | rows screen | delivered | src/list.ts:12'
R2='COVERAGE-ROW: R2 | name field | delivered | src/rows.ts:8'
R3='COVERAGE-ROW: R3 | empty state | delivered | src/empty.ts:4'

# ── C1-C3: the row list is the row count ────────────────────────────────────
for p in "$C0/plan-3-rows.md" "$C0/plan-4-rows.md" "$FX/plan.md"; do
  L=$(cr_plan_row_list "$p"); N=$(cr_plan_rows "$p")
  [ "$(grep -c . <<<"$L")" = "$N" ] && [ "$N" -gt 0 ] && ok || bad "C1 $(basename "$p"): list has $(grep -c . <<<"$L") line(s), cr_plan_rows says $N"
  grep -qE '^\|?[ :|-]+\|?$|Requirement \(quoted\)|ticket words' <<<"$L" && bad "C2 $(basename "$p"): header or separator printed: $L" || ok
done
L=$(cr_plan_row_list "$FX/plan.md")
[ "$(sed -n 2p <<<"$L")" = '"Each row has the `name` field" | T1, `src/rows.ts` | tests/rows.test.ts' ] && ok \
  || bad "C3 the row text is the cell text, outer pipes trimmed: $(sed -n 2p <<<"$L")"
printf '# Plan\n\n## Tasks\n\n- a\n' > "$T/nocov.md"
OUT=$(cr_plan_row_list "$T/nocov.md"); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "C3 no section: rc 1 and no output (rc $RC, '$OUT')"

# ── N1-N7: the note ─────────────────────────────────────────────────────────
NOTE=$(cv_review_note "$T/b/plan.md" "$FX/diff-names.txt")
grep -q '^Checklist-Version: 11$' <<<"$NOTE" && grep -q '^17\. ' <<<"$NOTE" && grep -q '^1\. Correctness against the ticket' <<<"$NOTE" && ok \
  || bad "N1 the checklist version line and items 1-17 are in the note"
grep -qE '^## Changes|^## Client questions|^- v1 2026-09-29' <<<"$NOTE" && bad "N1 the change log and client-questions block must not be in the note" || ok
[ "$(grep -E '^R[0-9]+: ' <<<"$NOTE" | cut -d: -f1 | paste -sd, -)" = R1,R2,R3 ] && ok || bad "N2 R1-R3 in plan order: $(grep -E '^R[0-9]+: ' <<<"$NOTE")"
grep -qF 'R2: "Each row has the `name` field"' <<<"$NOTE" && ok || bad "N2 R2 carries the row text"
grep -q '^NOT IN DIFF: R2 names src/rows.ts; the diff does not change them$' <<<"$NOTE" && ok || bad "N3 the NOT IN DIFF hint for R2: $(grep 'NOT IN DIFF' <<<"$NOTE")"
grep -q '^NOT IN DIFF: R[13] ' <<<"$NOTE" && bad "N4 R1 and R3 are in the diff, no hint" || ok
[ -z "$(cv_review_note "$T/nocov.md" "$FX/diff-names.txt")" ] && ok || bad "N5 a plan with no coverage gives no note"
OUT=$(COVERAGE_REVIEW_CHECKLIST_MAX_BYTES=100 cv_review_note "$T/b/plan.md" "$FX/diff-names.txt")
grep -q "^CHECKLIST: read $T/h/prompts/lead-review-checklist.md yourself" <<<"$OUT" && ok || bad "N6 the byte cap names the file: $(grep CHECKLIST <<<"$OUT")"
grep -q '^1\. Correctness' <<<"$OUT" && bad "N6 over the cap the items are not inlined" || ok
OUT=$(HARNESS="$T/none" cv_review_note "$T/b/plan.md" "$FX/diff-names.txt")
grep -q '^CHECKLIST: could not read ' <<<"$OUT" && ok || bad "N6 an unreadable checklist is named"
cat > "$T/two.md" <<'EOF'
## Requirements coverage

- "two files" in `src/rows.ts` and `src/list.ts`
- "a word only" with the `name` field
EOF
OUT=$(cv_review_note "$T/two.md" "$FX/diff-names.txt")
grep -q 'NOT IN DIFF' <<<"$OUT" && bad "N7 a row with one of two paths in the diff, or no path, gets no hint: $(grep 'NOT IN DIFF' <<<"$OUT")" || ok
OUT=$(COVERAGE_REVIEW_ROWS_MAX=2 cv_review_note "$T/b/plan.md" "$FX/diff-names.txt")
grep -q '^NOT JUDGED: R3' <<<"$OUT" && ! grep -q '^R3: ' <<<"$OUT" && ok || bad "N7 a row past ROWS_MAX is named NOT JUDGED"

# ── J1-J10: the rule ────────────────────────────────────────────────────────
# J1
use review-r2-missing.md
LENS_APPROVED review && bad "J1 a missing row must not be approved" || ok
grep -q '^- \[BLOCK wrong-data\] COVERAGE-GATE: R2 .*: missing$' "$T/b/review.md" && ok || bad "J1 the gate line: $(gate)"
[ "$(last)" = 'VERDICT: BLOCK' ] && ok || bad "J1 review.md must end VERDICT: BLOCK: $(last)"
# J7 (block case)
N=$(wc -l < "$T/b/review.md"); LENS_APPROVED review; [ "$(wc -l < "$T/b/review.md")" = "$N" ] && ok || bad "J7 a second call appends nothing"
# J2
review "$R1" "$R3"
LENS_APPROVED review && bad "J2 an untraced row must BLOCK" || ok
grep -q 'COVERAGE-GATE: R2 .*: not traced$' "$T/b/review.md" && ok || bad "J2 the reason: $(gate)"
# J3, J7 (ok case)
use review-all-delivered.md; cp "$T/b/review.md" "$T/before.md"; : > "$T/b/pipeline.log"
LENS_APPROVED review && cmp -s "$T/before.md" "$T/b/review.md" && ok || bad "J3 all delivered: approved and byte-identical: $(gate)"
grep -q 'COVERAGE-GATE' "$T/b/pipeline.log" && bad "J3 no gate line on OK" || ok
LENS_APPROVED review && cmp -s "$T/before.md" "$T/b/review.md" && ok || bad "J7 the ok case is idempotent"
# J4
review "$R1" '```' "$R2" '```' "$R3"
LENS_APPROVED review && bad "J4 a fenced row must not count" || ok
grep -q 'R2 .*: not traced' <<<"$(gate)" && ok || bad "J4 the reason: $(gate)"
review "$R1" "$R2" "$R3"
LENS_APPROVED review
printf '\n=== RE-REVIEW (head abc1234) ===\n%s\n%s\nTIER: 1\nVERDICT: APPROVE\n' "$R1" "$R3" >> "$T/b/review.md"
LENS_APPROVED review && bad "J4 an R2 row from an earlier pass does not count" || ok
# J5
review "$R1" 'COVERAGE-ROW: R2 | name field | missing | - | core-flow-broken' "$R3"
LENS_APPROVED review && bad "J5 must BLOCK" || ok
grep -q '^- \[BLOCK core-flow-broken\] COVERAGE-GATE: R2 ' "$T/b/review.md" && ok || bad "J5 column 5 sets the class: $(gate)"
# J6
review "$R1" 'COVERAGE-ROW: R2 | name field | missing | -' "$R3"; sed -i 's/^VERDICT: APPROVE$/VERDICT: BLOCK/' "$T/b/review.md"
cp "$T/b/review.md" "$T/before.md"
LENS_APPROVED review; cmp -s "$T/before.md" "$T/b/review.md" && ok || bad "J6 a BLOCK verdict is left alone"
# J8
for r in 'COVERAGE-ROW: R2 | name field | delivered | -' 'COVERAGE-ROW: R2 | name field | elsewhere | -' 'COVERAGE-ROW: R2 | name field | partial | src/rows.ts:8' 'COVERAGE-ROW: R2 | name field | contradicts | src/rows.ts:8'; do
  review "$R1" "$r" "$R3"
  LENS_APPROVED review && bad "J8 must BLOCK: $r" || ok
done
review "$R1" 'COVERAGE-ROW: R2 | name field | partial | src/rows.ts:8' "$R3"; LENS_APPROVED review
grep -q 'R2 .*: status "partial" is not delivered|missing|contradicts|elsewhere' <<<"$(gate)" && ok || bad "J8 the partial reason: $(gate)"
review "$R1" 'COVERAGE-ROW: R2 | name field | delivered | -' "$R3"; LENS_APPROVED review
grep -q 'R2 .*: delivered with no file:line' <<<"$(gate)" && ok || bad "J8 the delivered reason: $(gate)"
review "$R1" 'COVERAGE-ROW: R2 | name field | elsewhere | -' "$R3"; LENS_APPROVED review
grep -q 'R2 .*: elsewhere names no ticket or slice' <<<"$(gate)" && ok || bad "J8 the elsewhere reason: $(gate)"
use review-elsewhere.md
LENS_APPROVED review && ok || bad "J8 elsewhere naming a slice passes: $(gate)"
# J9
OUT=$(cv_enforce "$T/missing-review.md" "$T/b/plan.md"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "J9 an unreadable review: rc 0, no output"
# J10
EX=$(sed -n 's/^Example: //p' <<<"$NOTE")
[ -n "$EX" ] && ok || bad "J10 the note carries an Example: line"
review "$EX" "$R2" "$R3"
LENS_APPROVED review && ok || bad "J10 the note's own example row parses as delivered ($EX): $(gate)"
{ review "$R1" "$R2" "$R3"; printf '\nSPEC-TRACE-GATE: ok (cut-exempt=1)\nVERDICT: APPROVE\n' >> "$T/b/review.md"; }
LENS_APPROVED review && ok || bad "J10 rows before a restated SPEC-TRACE-GATE ok verdict count: $(gate)"

# ── E1-E5: the shipped review.sh blocks ─────────────────────────────────────
# E1
git -C "$T" init -q repo 2>/dev/null
REPO="$T/repo"; git -C "$REPO" config user.email fixture@example.com; git -C "$REPO" config user.name fixture
mkdir -p "$REPO/src"; echo base > "$REPO/src/list.ts"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)
echo 'export const list = [];' > "$REPO/src/list.ts"; echo 'empty' > "$REPO/src/empty.ts"
git -C "$REPO" add -A; git -C "$REPO" commit -qm 'fixture diff without src/rows.ts'
cd "$REPO" || exit 1
GATES_NOTE="before"; : > "$T/b/pipeline.log"
# shellcheck source=/dev/null
. "$T/note.sh"
case "$GATES_NOTE" in "before"$'\n'"COVERAGE REVIEW (lead checklist, BH-9499):"$'\n'*) ok ;; *) bad "E1 the region appends the block to GATES_NOTE: ${GATES_NOTE:0:200}" ;; esac
grep -q 'Checklist-Version: 11' <<<"$GATES_NOTE" && grep -q '^NOT IN DIFF: R2 names src/rows.ts' <<<"$GATES_NOTE" && ok || bad "E1 GATES_NOTE holds the checklist and the R2 hint"
[ "$(cat "$T/b/coverage-review-names.txt")" = "$(printf 'src/empty.ts\nsrc/list.ts')" ] && ok || bad "E1 the diff names: $(cat "$T/b/coverage-review-names.txt")"
grep -q 'COVERAGE REVIEW: 3 rows, checklist v11, 1 not in diff' "$T/b/pipeline.log" && ok || bad "E1 one pipeline.log line: $(cat "$T/b/pipeline.log")"
# E2: the acceptance case, no rows at all
use review-approve-norows.md
LENS_APPROVED review && bad "E2 a fixture diff that lacks the ticket's name field must not be approved" || ok
[ "$(grep -c 'COVERAGE-GATE: R[123] .*: not traced$' "$T/b/review.md")" = 3 ] && ok || bad "E2 every row is untraced: $(gate)"
verdict_is BLOCK -L "$T/b/review.md" && ok || bad "E2 verdict_is reads BLOCK"
# E4
mkdir -p "$T/h/logs"
HARNESS="$T/h" bash "$T/h/bin/findings-log.sh" "$T/b" widget-os FX-9499 >/dev/null 2>&1
grep -q 'ticket=FX-9499 lens=general verdict=BLOCK .*:: \[BLOCK wrong-data\] COVERAGE-GATE: R2' "$T/h/logs/findings.log" && ok \
  || bad "E4 findings-log records the gate BLOCK row: $(cat "$T/h/logs/findings.log" 2>/dev/null)"
# E3: a plan with no coverage
cp "$T/nocov.md" "$T/b/plan.md"
GATES_NOTE="before"; . "$T/note.sh"
[ "$GATES_NOTE" = before ] && ok || bad "E3 no coverage: GATES_NOTE unchanged"
use review-approve-norows.md; cp "$T/b/review.md" "$T/before.md"
LENS_APPROVED review && cmp -s "$T/before.md" "$T/b/review.md" && ok || bad "E3 no coverage: approved and byte-identical"
# E5: the acceptance case, R2 missing
cp "$FX/plan.md" "$T/b/plan.md"
use review-r2-missing.md
LENS_APPROVED review; RC=$?
[ "$RC" = 1 ] && ok || bad "E5 LENS_APPROVED review rc 1 (got $RC)"
grep -q '^- \[BLOCK wrong-data\] COVERAGE-GATE: R2 ' "$T/b/review.md" && [ "$(last)" = 'VERDICT: BLOCK' ] && ok || bad "E5 BLOCK lines in review.md: $(tail -4 "$T/b/review.md")"
grep -q 'COVERAGE-GATE: BLOCK — R2 ' "$T/b/pipeline.log" && ok || bad "E5 the pipeline.log gate line"
cd "$DIR" || exit 1

# Re-review: the merged prompt carries the rule.
RR=$(cv_rereview_note "$T/b/plan.md")
grep -q 'Re-emit the WHOLE COVERAGE-ROW block for the CURRENT head' <<<"$RR" && grep -q 'R1..R3' <<<"$RR" && ok || bad "the re-review note: $RR"
grep -E 'CC review .*RE-REVIEW AFTER ONE MERGED FIX ROUND.*cv_rereview_note "\$BUILD/plan.md"' "$RB_ALL" >/dev/null && ok \
  || bad "the merged re-review prompt must carry cv_rereview_note"
[ -z "$(cv_rereview_note "$T/nocov.md")" ] && ok || bad "a plan with no coverage adds nothing to the re-review prompt"

# ── K1-K3: the knobs ────────────────────────────────────────────────────────
REG="$DIR/catalog/lanes.d/_lib.coverage-review.json"
[ "$(jq -r '.libs[] | select(.id == "coverage-review") | .file' "$REG" 2>/dev/null)" = bin/lib/coverage-review.sh ] && ok \
  || bad "K1 the registry names bin/lib/coverage-review.sh"
for kv in COVERAGE_REVIEW_ENFORCE:CV_DEFAULT_ENFORCE COVERAGE_REVIEW_ROWS_MAX:CV_DEFAULT_ROWS_MAX COVERAGE_REVIEW_CHECKLIST_MAX_BYTES:CV_DEFAULT_CHECKLIST_MAX_BYTES; do
  KD=$(jq -r --arg e "${kv%%:*}" '.libs[] | select(.id == "coverage-review") | .knobs[] | select(.env == $e) | .default' "$REG" 2>/dev/null)
  LV="${kv##*:}"
  [ -n "$KD" ] && [ "$KD" = "${!LV}" ] && ok || bad "K1 ${kv%%:*}: registry '$KD' != lib $LV '${!LV}'"
done
# K2
use review-r2-missing.md; cp "$T/b/review.md" "$T/before.md"; : > "$T/b/pipeline.log"
COVERAGE_REVIEW_ENFORCE=0 LENS_APPROVED review && cmp -s "$T/before.md" "$T/b/review.md" && ok \
  || bad "K2 COVERAGE_REVIEW_ENFORCE=0: APPROVE stands and the file is unchanged"
grep -q 'COVERAGE-GATE: would BLOCK — R2 .*missing.*COVERAGE_REVIEW_ENFORCE=0' "$T/b/pipeline.log" && ok || bad "K2 the would-BLOCK line: $(cat "$T/b/pipeline.log")"
# K3
: > "$T/b/pipeline.log"
COVERAGE_REVIEW_ENFORCE=maybe LENS_APPROVED review && bad "K3 a bad ENFORCE value enforces" || ok
grep -q "COVERAGE_REVIEW_ENFORCE='maybe' is not on/off" "$T/b/pipeline.log" && ok || bad "K3 the warning: $(cat "$T/b/pipeline.log")"
COVERAGE_REVIEW_ROWS_MAX=abc cv_conf; [ "$CV_ROWS_MAX" = "$CV_DEFAULT_ROWS_MAX" ] && [ -n "$CV_CONF_WARN" ] && ok || bad "K3 a bad ROWS_MAX falls back and warns"

# ── Z1: no model call ───────────────────────────────────────────────────────
! grep -qE '(^|[^-])\b(claude|agent-call)[[:space:]]+-' "$0" && ok || bad "Z1 the suite invokes no model CLI"

echo "coverage-review.bh-9499: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

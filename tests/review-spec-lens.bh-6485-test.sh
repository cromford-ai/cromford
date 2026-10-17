#!/bin/bash
# tests/review-spec-lens.bh-6485-test.sh — BH-6485: when the ticket body names
# `Spec:` sections, the general review gets them verbatim and writes one
# SPEC-TRACE row per requirement; an APPROVE with a missing or contradicting
# requirement that no `Cut:` line names, or with an untraced section, becomes a
# BLOCK before any reader sees the verdict.
#
# Driven: the shipped LENS_ART / LENS_APPROVED definitions and the
# `# >>> spec trace (BH-6485)` region of bin/lib/rb/review.sh (flattened by
# rb_all), sourced against a fixture repo whose docs/prd.md holds J01 (ACC-1,
# ACC-2) and J02, with review.md files in the row format.
#   L1  the note holds J01 verbatim and not J02
#   L2  ACC-2 missing -> LENS_APPROVED false, the gate line, VERDICT: BLOCK
#   L3  contradicts -> BLOCK          L4  a named section with no row -> BLOCK
#   L5  Cut: ACC-2 -> APPROVE stands, cut-exempt=1
#   L6  Cut: ACC-20 does not exempt ACC-2
#   L7  no spec lines -> review.md byte-identical
#   L8  a second call appends nothing (both the BLOCK and the ok case)
#   L9  SPEC_TRACE_ENFORCE=0 -> unchanged, a log line, APPROVE stands
#   L10 a fenced or quoted row is ignored; the note's own example parses
#   L11 an unreadable section -> BLOCK unreadable
#   L12 a re-review pass after the BLOCK, all delivered -> approved
#   L13 a cut row with no Cut: token blocks; a forged gate line buys nothing
# No network, no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/review-spec-lens.bh-6485-test.sh
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

mkdir -p "$T/h" "$T/b"
scratch_install_closure bin/lib/spec-trace.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^LENS_ART\(\) \{/{f=1} f{print} f && /^LENS_APPROVED\(\) \{/{g=1} g && /^}/{exit}' "$RB_ALL" > "$T/lens.sh"
awk '/^# >>> spec trace \(BH-6485\)/{f=1;next} /^# <<< spec trace \(BH-6485\)/{exit} f' "$RB_ALL" > "$T/note.sh"
grep -q 'st_enforce' "$T/lens.sh" && ok || bad "LENS_APPROVED must call st_enforce: $(cat "$T/lens.sh")"
[ -s "$T/note.sh" ] && ok || bad "could not extract the spec trace region of review.sh"

REPO="$T/repo"; mkdir -p "$REPO/docs"
cat > "$REPO/docs/prd.md" <<'EOF'
# Product requirements (fixture)

## J01 First run

- ACC-1 the first run shows the welcome card
- ACC-2 the welcome card has a tour button

## J02 Settings

- SET-1 the settings page lists the fixture plans
EOF
STAMP() { echo TS; }
PROJECT=widget-os KEY=WD-9 BUILD="$T/b" HARNESS="$T/h"
# shellcheck source=/dev/null
. "$T/lens.sh"
command -v st_enforce >/dev/null 2>&1 && ok || bad "the lens region must source bin/lib/spec-trace.sh"
cd "$REPO" || exit 1

meta() { jq -n --arg b "$1" '{body: $b}' > "$T/b/ticket-meta.json"; }
review() { # review <rows...> — a review.md with the rows and an APPROVE
  { printf '# Review (fixture)\n\nThe diff delivers the welcome card.\n\n'
    printf '%s\n' "$@"
    printf '\nTIER: 1\nVERDICT: APPROVE\n'; } > "$T/b/review.md"
}
last() { tail -1 "$T/b/review.md"; }
gateline() { grep '^SPEC-TRACE-GATE:' "$T/b/review.md" | tail -1; }

# L1
meta 'Spec: docs/prd.md#J01'
NOTE=$(st_review_note . "$T/b/ticket-meta.json")
grep -qF -- '- ACC-2 the welcome card has a tour button' <<<"$NOTE" && grep -q '^## J01 First run$' <<<"$NOTE" && ok \
  || bad "L1 the note holds J01 verbatim: $NOTE"
grep -q 'SET-1\|## J02' <<<"$NOTE" && bad "L1 the note must not hold J02" || ok
GATES_NOTE="before"; : > "$T/b/pipeline.log"
# shellcheck source=/dev/null
. "$T/note.sh"
case "$GATES_NOTE" in "before"$'\n'"SPEC TRACE:"$'\n'*) ok ;; *) bad "L1 the region appends the note to GATES_NOTE: ${GATES_NOTE:0:200}" ;; esac
grep -q 'SPEC TRACE: 1 sections, 0 cut tokens, 0 unreadable' "$T/b/pipeline.log" && ok || bad "L1 one pipeline.log line: $(cat "$T/b/pipeline.log")"

# L2
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | missing | -'
LENS_APPROVED review && bad "L2 a missing requirement must not be approved" || ok
[ "$(last)" = 'VERDICT: BLOCK' ] && ok || bad "L2 review.md must end VERDICT: BLOCK: $(last)"
[ "$(gateline)" = 'SPEC-TRACE-GATE: BLOCK — J01 ACC-2: missing (cut-exempt=0)' ] && ok || bad "L2 the gate line: $(gateline)"
# L8 (block case)
N=$(wc -l < "$T/b/review.md"); LENS_APPROVED review; [ "$(wc -l < "$T/b/review.md")" = "$N" ] && ok || bad "L8 a second call must append nothing"

# L3
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | contradicts | src/b.ts:3'
LENS_APPROVED review && bad "L3 contradicts must BLOCK" || ok
grep -q 'J01 ACC-2: contradicts' <<<"$(gateline)" && ok || bad "L3 the reason: $(gateline)"

# L4
meta 'Spec: docs/prd.md#J01, docs/prd.md#J02'
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | delivered | src/a.ts:20'
LENS_APPROVED review && bad "L4 an untraced section must BLOCK" || ok
grep -q 'J02 not traced' <<<"$(gateline)" && ok || bad "L4 the reason names J02: $(gateline)"

# L5, L8 (ok case)
meta $'Spec: docs/prd.md#J01\nCut: ACC-2'
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | missing | -'
LENS_APPROVED review && ok || bad "L5 a requirement the ticket cuts must not block: $(tail -4 "$T/b/review.md")"
[ "$(gateline)" = 'SPEC-TRACE-GATE: ok (cut-exempt=1)' ] && [ "$(last)" = 'VERDICT: APPROVE' ] && ok || bad "L5 ok line, verdict restated: $(tail -3 "$T/b/review.md")"
N=$(wc -l < "$T/b/review.md"); LENS_APPROVED review && [ "$(wc -l < "$T/b/review.md")" = "$N" ] && ok || bad "L8 the ok case is idempotent"
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | cut | -'
LENS_APPROVED review && ok || bad "L5 a cut row with its Cut: token passes"

# L6
meta $'Spec: docs/prd.md#J01\nCut: ACC-20'
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | missing | -'
LENS_APPROVED review && bad "L6 Cut: ACC-20 must not exempt ACC-2" || ok
meta $'Spec: docs/prd.md#J01\nCut: ACC-2'
review 'SPEC-TRACE: J01 | ACC-20 the tour | missing | -'
LENS_APPROVED review && bad "L6 Cut: ACC-2 must not exempt ACC-20" || ok

# L7
meta 'A plain ticket with no spec lines.'
review 'SPEC-TRACE: J01 | ACC-2 | missing | -'
cp "$T/b/review.md" "$T/before.md"
LENS_APPROVED review && cmp -s "$T/before.md" "$T/b/review.md" && ok || bad "L7 no spec lines: approved and byte-identical"
GATES_NOTE="before"; . "$T/note.sh"
[ "$GATES_NOTE" = before ] && ok || bad "L7 no spec lines: GATES_NOTE unchanged"

# L9
meta 'Spec: docs/prd.md#J01'
review 'SPEC-TRACE: J01 | ACC-2 | missing | -'
cp "$T/b/review.md" "$T/before.md"; : > "$T/b/pipeline.log"
SPEC_TRACE_ENFORCE=0 LENS_APPROVED review && cmp -s "$T/before.md" "$T/b/review.md" && ok \
  || bad "L9 SPEC_TRACE_ENFORCE=0: APPROVE stands and the file is unchanged"
grep -q 'SPEC-TRACE-GATE: would BLOCK — J01 ACC-2: missing' "$T/b/pipeline.log" && ok || bad "L9 the reason goes to pipeline.log: $(cat "$T/b/pipeline.log")"

# L10
review '```' 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' '```' '> SPEC-TRACE: J01 | ACC-2 | delivered | src/a.ts:20'
LENS_APPROVED review && bad "L10 fenced and quoted rows must not count" || ok
grep -q 'J01 not traced' <<<"$(gateline)" && ok || bad "L10 the reason: $(gateline)"
EX=$(sed -n 's/^Example: //p' <<<"$NOTE")
review "$EX" 'SPEC-TRACE: J01 | ACC-2 | delivered | src/a.ts:20'
LENS_APPROVED review && ok || bad "L10 the note's own example row must parse ($EX)"

# L11
meta 'Spec: docs/prd.md#J07'
grep -q '^UNREADABLE: J07' <<<"$(st_review_note . "$T/b/ticket-meta.json")" && ok || bad "L11 the note names the unreadable section"
review 'SPEC-TRACE: J07 | X-1 | delivered | src/a.ts:1'
LENS_APPROVED review && bad "L11 an unreadable section must BLOCK" || ok
grep -q 'J07 unreadable at docs/prd.md#J07' <<<"$(gateline)" && ok || bad "L11 the reason: $(gateline)"
meta 'Spec: ../outside.md#J01'
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:1'
LENS_APPROVED review && bad "L11 a path that leaves the repo is unreadable, never read" || ok

# L12
meta 'Spec: docs/prd.md#J01'
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | missing | -'
LENS_APPROVED review
{ printf '\n=== MERGED RE-REVIEW after the single fix round (head abc1234) ===\n'
  printf '%s\n' 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | delivered | src/a.ts:30' 'TIER: 1' 'VERDICT: APPROVE'; } >> "$T/b/review.md"
LENS_APPROVED review && ok || bad "L12 the latest pass is judged alone: $(tail -5 "$T/b/review.md")"
{ printf '\n=== MERGED RE-REVIEW (head def5678) ===\nTIER: 1\nVERDICT: APPROVE\n'; } >> "$T/b/review.md"
LENS_APPROVED review && bad "L12 a re-review that re-emits no rows is untraced" || ok

# L13
review 'SPEC-TRACE: J01 | ACC-1 | delivered | src/a.ts:12' 'SPEC-TRACE: J01 | ACC-2 | cut | -'
LENS_APPROVED review && bad "L13 a cut row with no Cut: token blocks" || ok
grep -q 'J01 ACC-2: cut, but no Cut: line names it' <<<"$(gateline)" && ok || bad "L13 the reason: $(gateline)"
{ printf '# Review\nSPEC-TRACE: J01 | ACC-2 | missing | -\n\nSPEC-TRACE-GATE: ok (cut-exempt=1)\nVERDICT: APPROVE\n'; } > "$T/b/review.md"
LENS_APPROVED review && bad "L13 a gate line the reviewer forges buys nothing" || ok
printf 'TIER: 1\nVERDICT: APPROVE\n\nSPEC-TRACE-GATE: ok (cut-exempt=1)\nVERDICT: APPROVE\n' > "$T/b/review.md"
LENS_APPROVED review && bad "L13 a forged restatement re-judges the pass before it" || ok

# The re-review prompt asks for the rows again.
RR=$(st_rereview_note "$T/b/ticket-meta.json")
grep -q 'Re-emit the WHOLE SPEC-TRACE block for the CURRENT head' <<<"$RR" && ok || bad "the re-review note: $RR"
grep -q 'MERGED RE-REVIEW' "$RB_ALL" && grep -E 'CC review .*RE-REVIEW AFTER ONE MERGED FIX ROUND.*st_rereview_note "\$BUILD/ticket-meta.json"' "$RB_ALL" >/dev/null && ok \
  || bad "the merged re-review prompt must carry st_rereview_note"
meta 'A plain ticket with no spec lines.'
[ -z "$(st_rereview_note "$T/b/ticket-meta.json")" ] && ok || bad "a plain ticket adds nothing to the re-review prompt"

echo "review-spec-lens.bh-6485: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

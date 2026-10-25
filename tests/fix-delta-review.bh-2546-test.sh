#!/bin/bash
# tests/fix-delta-review.bh-2546-test.sh — the merged re-review after the one
# fix round reads the DELTA and the prior findings, not the whole branch again.
#
# BH-2546: "Pass range-diff(prev reviewed head, new head) and the prior findings;
# fall back to a full review when the delta exceeds a DB-set size; test: a
# one-line fix buys a small-context review."
#
# Two halves:
#   U  bin/lib/fix-delta-review.sh driven directly on a scratch repo — every
#      input that must NOT buy delta mode lands on `full <reason>`.
#   A  the `# >>> review lenses` block extracted VERBATIM from the pipeline (the
#      production entry point, same driver as tests/parallel-lenses-test.sh),
#      with a stubbed CC whose fix stage makes a REAL commit, so FIX_FROM..HEAD
#      is a delta the pipeline really produced. What is asserted is the prompt
#      the re-review call actually received and the pipeline.log line.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# TEST-CHANGE (BH-7970): the driven review/plan code sources $HARNESS/bin/lib/stage-prompt.sh and renders prompts/stages/*.md; the scratch harness carries both, as a synced box does.
scratch_install_closure bin/lib/stage-prompt.sh "$T" >/dev/null || bad "could not install bin/lib/stage-prompt.sh into the scratch harness"
mkdir -p "$T/prompts/stages"; cp "$DIR"/prompts/stages/*.md "$T/prompts/stages/"

LIB_SRC="$DIR/bin/lib/fix-delta-review.sh"
REG_SRC="$DIR/catalog/lanes.d/_lib.fix-delta-review.json"
# A scratch HARNESS carrying the lib and its registry file, and NO lane-gate.sh,
# so the knob resolves env > this checkout's registry default and nothing live.
mkdir -p "$T/bin/lib" "$T/catalog/lanes.d" "$T/logs" "$T/state" "$T/locks"
cp "$LIB_SRC" "$T/bin/lib/" 2>/dev/null || bad "bin/lib/fix-delta-review.sh does not exist"
cp "$REG_SRC" "$T/catalog/lanes.d/" 2>/dev/null || bad "catalog/lanes.d/_lib.fix-delta-review.json does not exist"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/findings-log.sh"; chmod +x "$T/bin/findings-log.sh"

gcommit() { git -c commit.gpgsign=false commit -qm "$1"; }

# ============================================================================
# U. the decision lib, driven directly
# ============================================================================
U="$T/u"
mkdir -p "$U"
( cd "$U" || exit 1
  git init -q -b main; git config user.email t@example.com; git config user.name tester
  echo base > README.md; git add -A; gcommit base
  git checkout -q -b feat
  echo work > a.txt; git add -A; gcommit work ) >/dev/null 2>&1
FROM=$(git -C "$U" rev-parse HEAD)
( cd "$U" && echo fix >> a.txt && git add -A && gcommit fix ) >/dev/null 2>&1
decide() { # decide <from> [env...] -> the lib's one line
  local from="$1"; shift
  ( cd "$U" && env HARNESS="$T" "$@" bash -c '. "$0" && fdr_decide main "$1" HEAD "$2"' \
      "$T/bin/lib/fix-delta-review.sh" "$from" "$T/u.diff" 2>/dev/null )
}
rm -f "$T/u.diff"
OUT=$(decide "$FROM")
[ "$OUT" = "delta 1 200" ] && ok || bad "U7 a one-line append at the registry default must be 'delta 1 200' (got: $OUT)"
grep -qE '^1: +[0-9a-f]+ = 1: ' "$T/u.diff" 2>/dev/null \
  && ok || bad "U7 the delta file carries no range-diff pair line for the reviewed commit: $(head -3 "$T/u.diff" 2>/dev/null)"
grep -qE '^-: +-+ > 2: ' "$T/u.diff" 2>/dev/null \
  && ok || bad "U7 the delta file does not show the fix commit as new in the range-diff"
grep -qx '+fix' "$T/u.diff" 2>/dev/null \
  && ok || bad "U7 the delta file does not carry the fix's own changed line"
OUT=$(decide "")
[ "$OUT" = "full no-prev-head" ] && ok || bad "U1 empty FIX_FROM must be full no-prev-head (got: $OUT)"
OUT=$(decide deadbeefdeadbeefdeadbeefdeadbeefdeadbeef)
[ "$OUT" = "full no-prev-head" ] && ok || bad "U2 a bogus sha must be full no-prev-head (got: $OUT)"
# The fix session amended the reviewed commit instead of adding one.
( cd "$U" && git checkout -q -b amended "$FROM" && echo amend >> a.txt && git add -A \
  && git -c commit.gpgsign=false commit -q --amend -m work2 ) >/dev/null 2>&1
OUT=$(decide "$FROM")
[ "$OUT" = "full history-rewritten" ] && ok || bad "U3 an amended head must be full history-rewritten (got: $OUT)"
( cd "$U" && git checkout -q -b bin "$FROM" && printf '\000\001\002' > blob.bin && git add -A && gcommit bin ) >/dev/null 2>&1
OUT=$(decide "$FROM")
[ "$OUT" = "full binary" ] && ok || bad "U4 a binary file in the delta must be full binary (got: $OUT)"
git -C "$U" checkout -q feat
OUT=$(decide "$FROM" FIX_DELTA_REVIEW_MAX_LINES=lots)
[ "$OUT" = "full knob-unresolved" ] && ok || bad "U5 a garbage knob must be full knob-unresolved, never small (got: $OUT)"
OUT=$(decide "$FROM" FIX_DELTA_REVIEW_MAX_LINES=0)
[ "$OUT" = "full knob-off" ] && ok || bad "U6 knob 0 must be full knob-off (got: $OUT)"
rm -f "$T/u.diff"
OUT=$(decide "$FROM" FIX_DELTA_REVIEW_MAX_LINES=0)
[ ! -e "$T/u.diff" ] && ok || bad "U6 a full decision must not write a delta file"
OUT=$(decide "$FROM" FIX_DELTA_REVIEW_MAX_BYTES=lots)
[ "$OUT" = "full knob-unresolved" ] && ok || bad "U9 a garbage byte knob must be full knob-unresolved (got: $OUT)"
# U8 — lines are not bytes: ONE numstat line of 60KB (a minified file) is under
# the line max but over the byte ceiling, and must never ride inline as argv.
( cd "$U" && git checkout -q -b long "$FROM" && head -c 60000 /dev/zero | tr '\0' x > min.js \
  && git add -A && gcommit long ) >/dev/null 2>&1
rm -f "$T/u.diff"
OUT=$(decide "$FROM")
[ "$OUT" = "full over-bytes" ] && ok || bad "U8 a one-line 60KB delta must be full over-bytes at the registry default (got: $OUT)"
[ ! -e "$T/u.diff" ] && ok || bad "U8 an over-bytes decision must not leave a delta file"
OUT=$(decide "$FROM" FIX_DELTA_REVIEW_MAX_BYTES=80000)
[ "${OUT%% *}" = delta ] && ok || bad "U8 the same delta under a raised byte ceiling must be delta (got: $OUT)"
git -C "$U" checkout -q feat

# ============================================================================
# A. the production lens block
# ============================================================================
awk '/^# >>> review lenses/{f=1;next} /^# <<< review lenses/{exit} f' "$RB_ALL" > "$T/lenses.sh"
[ -s "$T/lenses.sh" ] && ok || bad "could not extract the review-lens block — markers missing?"
awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' "$RB_ALL" > "$T/timing.sh"
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB_ALL" > "$T/suite-run.sh"

REPO="$T/repo"
setup_repo() { # setup_repo <file>...
  scratch_rm "$REPO"; mkdir -p "$REPO"
  ( cd "$REPO" || exit 1
    git init -q -b main; git config user.email t@example.com; git config user.name tester
    echo base > README.md; git add -A; gcommit base
    git checkout -q -b feat
    for f in "$@"; do mkdir -p "$(dirname "$f")"; echo x >> "$f"; done
    # WORK_LINES: a branch of realistic size, so "small context" is measured
    # against a whole-branch read that is not itself one line long.
    [ "${WORK_LINES:-0}" -gt 0 ] && seq 1 "$WORK_LINES" | sed 's/^/work line /' > work.txt
    git add -A; gcommit work ) >/dev/null 2>&1
}
run() { # run <env assignments...> -> RESULT or none; prompts land in $T/re-prompt.txt
  rm -rf "$T/build"; mkdir -p "$T/build"
  : > "$T/cc.log"; : > "$T/re-prompt.txt"
  ( cd "$REPO" || exit 1
    env HARNESS="$T" BUILD="$T/build" PROJECT=p KEY=K BASE=main BRANCH=feat \
        REVIEW_MODEL=rm FIX_MODEL=fm CCLOG="$T/cc.log" REPROMPT="$T/re-prompt.txt" \
        REOPEN_HOT=0 REOPEN_NOTE="" KIND_SKIP_SECLENS=0 REOPEN_EXTRA_LENS=0 \
        GATES_NOTE="" SPEC_DIR=.harness/specs LENSES_PARALLEL=1 FIX_LINES=1 \
        V_REVIEW=BLOCK V_SECURITY=APPROVE V_REFUTE=APPROVE \
        "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      BB() { :; }
      PUSH_BRANCH() { :; }
      CC() {
        local stage="$1" out="$4" prompt="$5" base i
        base=$(basename "$out")
        printf "start %s\n" "$base" >> "$CCLOG"
        case "$base" in
          review-run.txt)          printf "finding\nTIER: %s\nVERDICT: %s\n" "${PRIOR_TIER:-1}" "$V_REVIEW" > "$BUILD/review.md" ;;
          security-review-run.txt) printf "finding\nVERDICT: %s\n" "$V_SECURITY" > "$BUILD/security-review.md" ;;
          refute-review-run.txt)   printf "finding\nVERDICT: %s\n" "$V_REFUTE"   > "$BUILD/refute-review.md" ;;
          fix-run.txt)
            # A REAL fix commit of FIX_LINES lines, so FIX_FROM..HEAD is real.
            # STALE=1 leaves a delta file behind first, as an earlier resume would.
            [ "${STALE:-0}" = 1 ] && echo stale-delta > "$BUILD/fix-delta.diff"
            for i in $(seq 1 "$FIX_LINES"); do echo "fixed-line-$i" >> fixed.txt; done
            [ "${FIX_LONG:-0}" -gt 0 ] && head -c "$FIX_LONG" /dev/zero | tr "\\0" y > min.js
            git add -A && git -c commit.gpgsign=false commit -qm fix ;;
          review2-run.txt)
            printf "%s" "$prompt" > "$REPROMPT"
            if [ "$LENSES_PARALLEL" = 1 ]; then
              { echo "merged findings"; echo "TIER: ${RE_TIER:-1}"; echo "VERDICT-REVIEW: APPROVE"
                grep -q security-review.md <<<"$prompt" && echo "VERDICT-SECURITY: APPROVE"
                grep -q refute-review.md   <<<"$prompt" && echo "VERDICT-REFUTE: APPROVE"
              } > "$BUILD/merged-review2.md"
            else
              printf "finding2\nTIER: 1\nVERDICT: APPROVE\n" >> "$BUILD/review.md"
            fi ;;
        esac
      }
      . "$1"
      . "$2"
      . "$0"
    ' "$T/lenses.sh" "$T/timing.sh" "$T/suite-run.sh" >/dev/null 2>&1 )
  cat "$T/build/RESULT" 2>/dev/null || echo none
}
fdr_line() { grep -o 'FIX-DELTA-REVIEW .*' "$T/build/pipeline.log" 2>/dev/null; }
FULL_MARK='general adversarial review of the CURRENT diff'

# A3 first, so A1 can compare its context against a real full-mode context.
# CONTEXT, not prompt bytes: a full-mode prompt is short text that sends the
# reviewer to read `git diff main...HEAD`; a delta-mode prompt carries its delta
# inline and sends it nowhere else. So a full review's context is its prompt
# plus the branch diff it is told to read, and a delta review's is its prompt.
WORK_LINES=300 setup_repo app/page.tsx
OUT=$(run FIX_LINES=6 FIX_DELTA_REVIEW_MAX_LINES=5)
[ "$OUT" = none ] && ok || bad "A3 a re-approved build must not terminate (got: $OUT)"
fdr_line | grep -q '^FIX-DELTA-REVIEW mode=full .*reason=over-max' \
  && ok || bad "A3 a 6-line fix over a max of 5 must log mode=full reason=over-max (got: $(fdr_line))"
grep -qF "$FULL_MARK (git diff main...HEAD)" "$T/re-prompt.txt" \
  && ok || bad "A3 full mode must keep today's whole-branch instruction"
[ ! -e "$T/build/fix-delta.diff" ] && ok || bad "A3 full mode left a fix-delta.diff behind"
FULL_LEN=$(( $(wc -c < "$T/re-prompt.txt") + $(git -C "$REPO" diff main...HEAD | wc -c) ))

# A1 — a one-line fix buys a small-context review.
WORK_LINES=300 setup_repo app/page.tsx
OUT=$(run FIX_LINES=1)
[ "$OUT" = none ] && ok || bad "A1 a re-approved build must not terminate (got: $OUT)"
fdr_line | grep -q '^FIX-DELTA-REVIEW mode=delta lines=1 max=200' \
  && ok || bad "A1 a one-line fix must log mode=delta lines=1 max=200 (got: $(fdr_line))"
[ -s "$T/build/fix-delta.diff" ] && ok || bad "A1 delta mode wrote no \$BUILD/fix-delta.diff"
grep -qx '+fixed-line-1' "$T/re-prompt.txt" \
  && ok || bad "A1 the re-review prompt does not carry the fix's own changed line"
grep -qE -- '-: +-+ > [0-9]+: +[0-9a-f]+ fix' "$T/re-prompt.txt" \
  && ok || bad "A1 the re-review prompt does not carry the range-diff of the reviewed head vs the new head"
grep -qF "$FULL_MARK" "$T/re-prompt.txt" \
  && bad "A1 delta mode still asks for a general review of the whole branch diff" || ok
D_LEN=$(wc -c < "$T/re-prompt.txt" | tr -d ' ')
[ "${D_LEN:-0}" -gt 0 ] && [ "${D_LEN:-0}" -lt "${FULL_LEN:-0}" ] \
  && ok || bad "A1 the delta review's context ($D_LEN bytes) is not smaller than the full review's ($FULL_LEN bytes: prompt + branch diff)"
[ "$(grep -c 'start review2-run.txt' "$T/cc.log")" = 1 ] \
  && ok || bad "A1 expected exactly one re-review call, got: $(paste -sd, "$T/cc.log")"
grep -q 'HARNESS_EXIT\|harness-suite-fix.txt' "$T/re-prompt.txt" \
  && ok || bad "A1 the delta prompt dropped the suite ground truth"
grep -q 'VERDICT-REVIEW:' "$T/re-prompt.txt" \
  && ok || bad "A1 the delta prompt dropped the output contract tags"
tail -1 "$T/build/review.md" 2>/dev/null | grep -qx 'VERDICT: APPROVE' \
  && ok || bad "A1 the verdict fan-out did not land on review.md (tail: $(tail -1 "$T/build/review.md" 2>/dev/null))"

# A2 — the prior findings of every refusing lens are named.
setup_repo src/middleware.ts
OUT=$(run V_REVIEW=BLOCK V_SECURITY=BLOCK)
fdr_line | grep -q '^FIX-DELTA-REVIEW mode=delta' && ok || bad "A2 expected delta mode (got: $(fdr_line))"
grep -q 'PRIOR FINDINGS' "$T/re-prompt.txt" \
  && ok || bad "A2 the delta prompt carries no prior-findings instruction"
for F in review.md security-review.md; do
  grep -qF "$T/build/$F" "$T/re-prompt.txt" && ok || bad "A2 the delta prompt never names the prior findings file $F"
done
tail -1 "$T/build/security-review.md" 2>/dev/null | grep -qx 'VERDICT: APPROVE' \
  && ok || bad "A2 the security verdict fan-out did not land"

# A4 — the boundary is inclusive, and 0 is the kill switch.
setup_repo app/page.tsx
run FIX_LINES=6 FIX_DELTA_REVIEW_MAX_LINES=6 >/dev/null
fdr_line | grep -q '^FIX-DELTA-REVIEW mode=delta lines=6 max=6' \
  && ok || bad "A4 6 lines at max 6 must be delta (got: $(fdr_line))"
setup_repo app/page.tsx
run FIX_LINES=1 FIX_DELTA_REVIEW_MAX_LINES=0 >/dev/null
fdr_line | grep -q '^FIX-DELTA-REVIEW mode=full .*reason=knob-off' \
  && ok || bad "A4 max 0 must be full reason=knob-off (got: $(fdr_line))"
grep -qF "$FULL_MARK" "$T/re-prompt.txt" && ok || bad "A4 knob-off did not give today's full prompt"

# A5 — the knob is a registered lib knob with a 200 default the lib resolves.
[ "$(jq -r '.libs[0].knobs[0] | "\(.env) \(.default) \(.required)"' "$REG_SRC" 2>/dev/null)" = "FIX_DELTA_REVIEW_MAX_LINES 200 true" ] \
  && ok || bad "A5 the registry file does not declare FIX_DELTA_REVIEW_MAX_LINES default 200 required"
OUT=$(env -u FIX_DELTA_REVIEW_MAX_LINES HARNESS="$T" bash -c '. "$0" && fdr_max_lines' "$T/bin/lib/fix-delta-review.sh" 2>/dev/null)
[ "$OUT" = 200 ] && ok || bad "A5 with no env and no settings row the lib must resolve 200 (got: $OUT)"

OUT=$(env -u FIX_DELTA_REVIEW_MAX_BYTES HARNESS="$T" bash -c '. "$0" && fdr_max_bytes' "$T/bin/lib/fix-delta-review.sh" 2>/dev/null)
[ "$OUT" = 48000 ] && ok || bad "A5 with no env and no settings row the byte ceiling must resolve 48000 (got: $OUT)"
[ "$(jq -r '.libs[0].knobs[] | select(.env == "FIX_DELTA_REVIEW_MAX_BYTES") | "\(.default) \(.max) \(.required)"' "$REG_SRC" 2>/dev/null)" = "48000 80000 true" ] \
  && ok || bad "A5 the registry file does not declare FIX_DELTA_REVIEW_MAX_BYTES default 48000 max 80000 required"

# A6 — no model id in the new lib or the lens block.
if [ -f "$LIB_SRC" ] && ! grep -q 'claude-' "$LIB_SRC" && ! grep -q 'claude-' "$T/lenses.sh"; then ok
else bad "A6 a claude- model string is in the lib or the lens block (or the lib is missing)"; fi

# A7 — the sequential rollback path is untouched.
setup_repo app/page.tsx
run LENSES_PARALLEL=0 >/dev/null
grep -q 'Re-review after fixes' "$T/re-prompt.txt" \
  && ok || bad "A7 the sequential re-review prompt changed: $(head -c 120 "$T/re-prompt.txt")"
[ -z "$(fdr_line)" ] && ok || bad "A7 the sequential path must not run the delta decision (got: $(fdr_line))"

# A8 — the lib absent from $HARNESS/bin/lib: full, never delta.
mv "$T/bin/lib/fix-delta-review.sh" "$T/fdr.away" 2>/dev/null
setup_repo app/page.tsx
run FIX_LINES=1 >/dev/null
fdr_line | grep -q '^FIX-DELTA-REVIEW mode=full .*reason=lib-unavailable' \
  && ok || bad "A8 a missing lib must log mode=full reason=lib-unavailable (got: $(fdr_line))"
grep -qF "$FULL_MARK" "$T/re-prompt.txt" && ok || bad "A8 a missing lib did not give today's full prompt"
mv "$T/fdr.away" "$T/bin/lib/fix-delta-review.sh" 2>/dev/null

# A9 — a stale delta file from an earlier resume never survives a full decision.
setup_repo app/page.tsx
run STALE=1 FIX_LINES=6 FIX_DELTA_REVIEW_MAX_LINES=5 >/dev/null
[ ! -e "$T/build/fix-delta.diff" ] && ok || bad "A9 full mode kept a stale fix-delta.diff"
grep -q stale-delta "$T/re-prompt.txt" && bad "A9 a stale delta reached the prompt" || ok

# A10 — a delta re-review never lowers the whole-branch tier. The general lens
# tiered the branch 2; the delta reviewer, shown only a small fix, writes 1.
# The build's tier (the TIER line appended to review.md, which pr.sh reads)
# stays 2.
merged_tier() { grep -A1000 'MERGED RE-REVIEW after' "$T/build/review.md" 2>/dev/null | grep -E '^TIER: [12]$' | tail -1; }
setup_repo lib/export.ts
OUT=$(run FIX_LINES=1 PRIOR_TIER=2 RE_TIER=1)
fdr_line | grep -q '^FIX-DELTA-REVIEW mode=delta' && ok || bad "A10 expected delta mode (got: $(fdr_line))"
[ "$(merged_tier)" = "TIER: 2" ] && ok || bad "A10 prior TIER: 2 + delta TIER: 1 must end TIER: 2 (got: $(merged_tier))"
grep -q 'TIER: 1' <<<"$(tail -2 "$T/build/review.md")" && bad "A10 pr.sh's tail -2 read of review.md would see TIER: 1" || ok
grep -q 'DELTA-TIER-FLOOR' "$T/build/pipeline.log" 2>/dev/null && ok || bad "A10 the tier floor left no pipeline.log line"
grep -qF "tiered the WHOLE branch 'TIER: 2'" "$T/re-prompt.txt" && ok || bad "A10 the delta prompt does not carry the prior tier as a floor"
# A11 — the floor only ever raises: prior 1 + delta 1 stays 1, prior 1 + delta 2 is 2.
setup_repo app/page.tsx
run FIX_LINES=1 PRIOR_TIER=1 RE_TIER=1 >/dev/null
[ "$(merged_tier)" = "TIER: 1" ] && ok || bad "A11 prior 1 + delta 1 must stay TIER: 1 (got: $(merged_tier))"
setup_repo app/page.tsx
run FIX_LINES=1 PRIOR_TIER=1 RE_TIER=2 >/dev/null
[ "$(merged_tier)" = "TIER: 2" ] && ok || bad "A11 prior 1 + delta 2 must be TIER: 2 (got: $(merged_tier))"

# A12 — a one-line fix that is 60KB long goes full, never inline as argv.
setup_repo app/page.tsx
run FIX_LINES=0 FIX_LONG=60000 >/dev/null
fdr_line | grep -q '^FIX-DELTA-REVIEW mode=full .*reason=over-bytes' \
  && ok || bad "A12 a 60KB one-line fix must log mode=full reason=over-bytes (got: $(fdr_line))"
grep -qF "$FULL_MARK" "$T/re-prompt.txt" && ok || bad "A12 over-bytes did not give today's full prompt"
[ "$(wc -c < "$T/re-prompt.txt")" -lt 20000 ] && ok || bad "A12 the over-bytes prompt still carries the delta inline"

echo "fix-delta-review: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

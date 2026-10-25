#!/bin/bash
# tests/parallel-lenses-test.sh — the three review lenses read ONE diff, so they
# read it at the same time.
#
# What changed, and therefore what has to be pinned here: the general REVIEW,
# the SECURITY lens and the adversarial REFUTER used to run strictly one after
# another, each with its OWN fix round and its OWN re-review, and each of those
# fix rounds committed past `review-head` and re-triggered the head-bound gate.
# Now the three reviews run concurrently, ONE fix round is handed all of their
# findings together, the suite is re-run once, and ONE re-review adjudicates
# each lens's objection separately.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q LENSES_PARALLEL bin/run-build.sh` passes
# just as happily on a version that launches three lenses and then ignores two
# of their verdicts, or on one that silently drops the SECURITY_BLOCKED
# terminal. What is under test is the control flow: that the calls really do
# overlap, that exactly one fix round is bought and it can SEE every lens's
# findings, that a lens which still refuses after the merged round exits with
# ITS OWN terminal, and that the rollback switch reproduces the old call order.
#
# The block is extracted VERBATIM from bin/run-build.sh by its markers, so a
# regression in the real lines fails here rather than in a paraphrase.
# Run from anywhere: tests/parallel-lenses-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# TEST-CHANGE (BH-7970): the driven review/plan code sources $HARNESS/bin/lib/stage-prompt.sh and renders prompts/stages/*.md; the scratch harness carries both, as a synced box does.
scratch_install_closure bin/lib/stage-prompt.sh "$T" >/dev/null || bad "could not install bin/lib/stage-prompt.sh into the scratch harness"
mkdir -p "$T/prompts/stages"; cp "$DIR"/prompts/stages/*.md "$T/prompts/stages/"

awk '/^# >>> review lenses/{f=1;next} /^# <<< review lenses/{exit} f' \
  "$RB_ALL" > "$T/lenses.sh"
[ -s "$T/lenses.sh" ] && ok || bad "could not extract the review-lens block from bin/run-build.sh — markers missing?"
grep -q 'LENSES_PARALLEL' "$T/lenses.sh" \
  && ok || bad "the extracted block carries no LENSES_PARALLEL switch — wrong markers, or the switch is missing"

# The lens block runs the repo's own suite twice — once before the lenses read
# the diff, once on the fixed head — through HARNESS_SUITE_RUN, which lives in
# its own marked block with the stage timers it calls. Both are extracted
# VERBATIM for the same reason the lens block is: a stub here would let the real
# function break while this suite stayed green.
awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' \
  "$RB_ALL" > "$T/timing.sh"
[ -s "$T/timing.sh" ] && ok || bad "could not extract the stage-timing block — markers missing?"
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' \
  "$RB_ALL" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

# findings-log.sh is called once per lens and must never be able to fail a build.
printf '#!/bin/bash\nexit 0\n' > "$T/bin/findings-log.sh"; chmod +x "$T/bin/findings-log.sh"

REPO="$T/repo"
setup_repo() { # setup_repo <file>...   — files whose NAMES decide which lenses run
  scratch_rm "$REPO"; mkdir -p "$REPO"
  ( cd "$REPO" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo base > README.md
    git add -A; git -c commit.gpgsign=false commit -qm base
    git checkout -q -b feat
    for f in "$@"; do mkdir -p "$(dirname "$f")"; echo x >> "$f"; done
    git add -A; git -c commit.gpgsign=false commit -qm work ) >/dev/null 2>&1
}

# The driver. Every verdict the stubbed reviewer gives is an env var, so each
# row below is one shape of "who blocked, and did the merged round fix it".
#   V_REVIEW/V_SECURITY/V_REFUTE     round-1 verdicts (`none` = the session died)
#   V2_REVIEW/V2_SECURITY/V2_REFUTE  what the re-review says afterwards
run() { # run <env assignments...>   -> prints the final RESULT (or "none")
  rm -rf "$T/build"; mkdir -p "$T/build"
  : > "$T/cc.log"; : > "$T/fix-prompt.txt"; : > "$T/re-prompt.txt"
  ( cd "$REPO" || exit 1
    env HARNESS="$T" BUILD="$T/build" PROJECT=p KEY=K BASE=main BRANCH=feat \
        REVIEW_MODEL=rm FIX_MODEL=fm \
        CCLOG="$T/cc.log" FIXPROMPT="$T/fix-prompt.txt" REPROMPT="$T/re-prompt.txt" \
        REOPEN_HOT=0 REOPEN_NOTE="" KIND_SKIP_SECLENS=0 REOPEN_EXTRA_LENS=0 \
        GATES_NOTE="" SPEC_DIR=.harness/specs CC_SLEEP="${CC_SLEEP:-2}" \
        REALCC="$T/real-cc.sh" CG_ORIENT=x \
        V_REVIEW=APPROVE V_SECURITY=APPROVE V_REFUTE=APPROVE \
        V2_REVIEW=APPROVE V2_SECURITY=APPROVE V2_REFUTE=APPROVE \
        "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      BB() { :; }
      PUSH_BRANCH() { :; }
      # Stands in for job_beat_start: a background child of THIS shell that
      # outlives every lens. Nothing in the block may wait on it.
      [ "${BEATER:-0}" = 1 ] && { sleep 60 & }
      # The stubbed agent. It records when it STARTED and when it FINISHED, so
      # overlap is a fact in the log rather than a wall-clock guess, and it
      # writes whichever artifact the real lens would have written.
      CC() {
        local stage="$1" out="$4" prompt="$5" base
        base=$(basename "$out")
        # Section 8: this one call goes through the REAL CC() (extracted from
        # run-build), over a stub agent-call that answers a day-cap refusal.
        if [ -n "${DEFER_LENS:-}" ] && [ "$base" = "$DEFER_LENS" ]; then
          printf "%s start %s\n" "$(date +%s)" "$base" >> "$CCLOG"
          REAL_CC "$@"; return $?
        fi
        printf "%s start %s\n" "$(date +%s)" "$base" >> "$CCLOG"
        [ "$stage" = fix ] && printf "%s" "$prompt" > "$FIXPROMPT"
        sleep "$CC_SLEEP"
        case "$base" in
          review-run.txt)
            [ "$V_REVIEW"   = none ] || printf "finding\nTIER: 1\nVERDICT: %s\n" "$V_REVIEW"   > "$BUILD/review.md" ;;
          security-review-run.txt)
            [ "$V_SECURITY" = none ] || printf "finding\nVERDICT: %s\n" "$V_SECURITY" > "$BUILD/security-review.md" ;;
          refute-review-run.txt)
            [ "$V_REFUTE"   = none ] || printf "finding\nVERDICT: %s\n" "$V_REFUTE"   > "$BUILD/refute-review.md" ;;
          review2-run.txt)
            printf "%s" "$prompt" > "$REPROMPT"
            if [ "${LENSES_PARALLEL:-0}" != 1 ]; then
              printf "finding2\nTIER: 1\nVERDICT: %s\n" "$V2_REVIEW" >> "$BUILD/review.md"
            elif [ "$V2_REVIEW" != none ]; then
              { echo "merged findings"; echo "TIER: 1"
                echo "VERDICT-REVIEW: $V2_REVIEW"
                grep -q security-review.md <<<"$prompt" && echo "VERDICT-SECURITY: $V2_SECURITY"
                grep -q refute-review.md   <<<"$prompt" && echo "VERDICT-REFUTE: $V2_REFUTE"
              } > "$BUILD/merged-review2.md"
            fi ;;
          security-review2-run.txt)
            printf "finding2\nVERDICT: %s\n" "$V2_SECURITY" >> "$BUILD/security-review.md" ;;
          refute-review2-run.txt)
            printf "finding2\nVERDICT: %s\n" "$V2_REFUTE" >> "$BUILD/refute-review.md" ;;
        esac
        printf "%s end %s\n" "$(date +%s)" "$base" >> "$CCLOG"
      }
      [ -n "${DEFER_LENS:-}" ] && . "$REALCC"
      . "$1"
      . "$2"
      . "$0"
    ' "$T/lenses.sh" "$T/timing.sh" "$T/suite-run.sh" >/dev/null 2>&1 )
  cat "$T/build/RESULT" 2>/dev/null || echo none
}
calls() { awk '$2=="start"{print $3}' "$T/cc.log"; }
seq_order() { awk '{print $2" "$3}' "$T/cc.log" | paste -sd, -; }

# ============================================================================
# 1. PARALLEL: the three lenses actually overlap
# ============================================================================
setup_repo src/middleware.ts prisma/schema.prisma app/page.tsx
OUT=$(run LENSES_PARALLEL=1)
[ "$OUT" = none ] && ok || bad "three APPROVEs must not terminate the build (got: $OUT)"
[ "$(calls | wc -l | tr -d ' ')" = 3 ] \
  && ok || bad "the diff earns all three lenses; got: $(calls | paste -sd, -)"
calls | grep -qx review-run.txt          && ok || bad "the general lens did not run"
calls | grep -qx security-review-run.txt && ok || bad "the security lens did not run on a risky diff"
calls | grep -qx refute-review-run.txt   && ok || bad "the refuter did not run on a schema diff"
# THE PROPERTY. Every lens had started before any had finished — three starts,
# then three ends. Sequentially this log reads start,end,start,end,start,end.
[ "$(awk 'NR<=3{print $2}' "$T/cc.log" | sort -u)" = start ] \
  && ok || bad "the lenses did not overlap — call log: $(seq_order)"
MAXSTART=$(awk '$2=="start"{print $1}' "$T/cc.log" | sort -n | tail -1)
MINEND=$(awk   '$2=="end"{print $1}'   "$T/cc.log" | sort -n | head -1)
[ "${MAXSTART:-0}" -lt "${MINEND:-0}" ] \
  && ok || bad "no instant existed when all three lenses were running (last start ${MAXSTART:-?}, first end ${MINEND:-?})"
[ "$(cat "$T/build/review-head" 2>/dev/null)" = "$(cd "$REPO" && git rev-parse HEAD)" ] \
  && ok || bad "review-head was not bound to the reviewed head after every lens approved"

# THE HANG. bin/run-build.sh already owns a background child that never exits —
# job_beat_start's heartbeat loop, launched at claim time and killed only on
# EXIT. A bare `wait` in the lens block would block on THAT until the claim
# timed out, so the fastest stage in the pipeline would become the one that
# hangs every build. Here a sleeper stands in for the beater: the block must
# come back anyway, and it must come back in about one lens's time, not three.
HANG0=$(date +%s)
OUT=$(run LENSES_PARALLEL=1 BEATER=1)
HANGD=$(( $(date +%s) - HANG0 ))
[ "$OUT" = none ] && ok || bad "the lens block did not complete with a long-lived background sibling (got: $OUT)"
[ "$HANGD" -lt 20 ] \
  && ok || bad "the lens block waited on a background sibling it does not own (${HANGD}s — a bare 'wait'?)"

# ============================================================================
# 2. PARALLEL: one merged fix round, and it can see every lens's findings
# ============================================================================
setup_repo src/middleware.ts prisma/schema.prisma
OUT=$(run LENSES_PARALLEL=1 V_REVIEW=BLOCK V_SECURITY=BLOCK V_REFUTE=BLOCK)
[ "$OUT" = none ] && ok || bad "a merged round that re-approved everything must not terminate (got: $OUT)"
[ "$(calls | grep -c 'fix-run.txt')" = 1 ] \
  && ok || bad "expected exactly ONE fix round, got: $(calls | paste -sd, -)"
grep -q 'security-fix-run.txt\|refute-fix-run.txt' <<<"$(calls)" \
  && bad "the per-lens fix rounds are still being bought: $(calls | paste -sd, -)" || ok
for F in review.md security-review.md refute-review.md; do
  grep -q "$F" "$T/fix-prompt.txt" \
    && ok || bad "the merged fix prompt never names $F — that lens's findings were not handed over"
done
[ "$(calls | grep -c 'review2-run.txt')" = 1 ] \
  && ok || bad "expected exactly ONE re-review, got: $(calls | paste -sd, -)"
grep -q 'security-review2-run.txt\|refute-review2-run.txt' <<<"$(calls)" \
  && bad "per-lens re-reviews are still being bought: $(calls | paste -sd, -)" || ok
grep -q 'HARNESS_EXIT' "$T/build/harness-suite-fix.txt" 2>/dev/null \
  && ok || bad "the suite was not re-run on the fixed head — the re-reviewer got no ground truth"
# Every lens artifact ends on the verdict the merged re-review gave it.
for F in review.md security-review.md refute-review.md; do
  tail -1 "$T/build/$F" 2>/dev/null | grep -qx 'VERDICT: APPROVE' \
    && ok || bad "$F does not end on the re-review's verdict (tail: $(tail -1 "$T/build/$F" 2>/dev/null))"
done
# review.md keeps its two-line contract: TIER then VERDICT.
tail -2 "$T/build/review.md" | head -1 | grep -qE '^TIER: [12]$' \
  && ok || bad "review.md lost its 'TIER: n' second-to-last line after the merged re-review"

# ============================================================================
# 3. PARALLEL: a lens that still refuses exits with ITS OWN terminal
# ============================================================================
setup_repo src/middleware.ts prisma/schema.prisma
OUT=$(run LENSES_PARALLEL=1 V_SECURITY=BLOCK V2_SECURITY=BLOCK)
grep -q '^SECURITY_BLOCKED .*security-review.md' <<<"$OUT" \
  && ok || bad "a security lens that still refuses must terminate SECURITY_BLOCKED (got: $OUT)"

OUT=$(run LENSES_PARALLEL=1 V_REFUTE=BLOCK V2_REFUTE=BLOCK)
grep -q '^REFUTE_BLOCKED .*refute-review.md' <<<"$OUT" \
  && ok || bad "a refuter that still refuses must terminate REFUTE_BLOCKED (got: $OUT)"

OUT=$(run LENSES_PARALLEL=1 V_REVIEW=BLOCK V2_REVIEW=BLOCK)
grep -q '^REVIEW_BLOCKED .*review.md' <<<"$OUT" \
  && ok || bad "a general lens that still refuses must terminate REVIEW_BLOCKED (got: $OUT)"

# Several lenses refusing names the general one first — the same precedence the
# sequential flow had, where the general lens was simply reached first.
OUT=$(run LENSES_PARALLEL=1 V_REVIEW=BLOCK V_SECURITY=BLOCK V2_REVIEW=BLOCK V2_SECURITY=BLOCK)
grep -q '^REVIEW_BLOCKED' <<<"$OUT" \
  && ok || bad "with several lenses refusing the terminal must be the general one (got: $OUT)"

# A re-review that produced NO verdict file is not an approval. Silence is the
# one answer that must never read as PASS.
OUT=$(run LENSES_PARALLEL=1 V_REVIEW=BLOCK V2_REVIEW=none)
grep -q '^REVIEW_BLOCKED' <<<"$OUT" \
  && ok || bad "a re-review with no verdict file was treated as an approval (got: $OUT)"

# A lens that approved BEFORE the fix round, and which the merged re-review then
# overturns on the fixed head, must still block: its round-1 APPROVE was about a
# tree that no longer exists.
OUT=$(run LENSES_PARALLEL=1 V_REVIEW=BLOCK V_SECURITY=APPROVE V2_SECURITY=BLOCK)
grep -q '^SECURITY_BLOCKED' <<<"$OUT" \
  && ok || bad "the re-review overturned the security lens on the fixed head and the build sailed on (got: $OUT)"

# ============================================================================
# 4. LENS SELECTION is unchanged — a docs diff still buys exactly one reviewer
# ============================================================================
setup_repo docs/notes.md
OUT=$(run LENSES_PARALLEL=1)
[ "$(calls | wc -l | tr -d ' ')" = 1 ] \
  && ok || bad "a docs-only diff must buy one lens, got: $(calls | paste -sd, -)"
calls | grep -qx review-run.txt && ok || bad "the one lens a docs diff buys must be the general review"

setup_repo src/middleware.ts
OUT=$(run LENSES_PARALLEL=1)
[ "$(calls | wc -l | tr -d ' ')" = 2 ] \
  && ok || bad "a risky-but-not-money diff must buy two lenses, got: $(calls | paste -sd, -)"
grep -qx refute-review-run.txt <<<"$(calls)" \
  && bad "the refuter ran on a diff with no schema or money files" || ok

# ============================================================================
# 5. THE DEFAULT IS PARALLEL (2026-09-14). It shipped sequential on 2026-09-12
#    with project-5 as the pilot; after two days of real pool builds on the
#    parallel flow, the operator's order was that build, conductor, review and merge all
#    run parallel with no caps, so the default flipped. Driven with the variable
#    UNSET, which is the state every project is in — no env/<project>.env line
#    is needed to get three lenses at once.
# ============================================================================
setup_repo src/middleware.ts prisma/schema.prisma
OUT=$(run)
[ "$(awk 'NR<=2{print $2}' "$T/cc.log" | paste -sd, -)" = "start,start" ] \
  && ok || bad "with LENSES_PARALLEL unset the lenses ran sequentially: $(seq_order)"
# A value that is neither 0 nor 1 is a typo, and a typo must fall back to the
# proven sequential path rather than be read as the default.
OUT=$(run LENSES_PARALLEL=yes)
[ "$(awk 'NR<=2{print $2}' "$T/cc.log" | paste -sd, -)" = "start,end" ] \
  && ok || bad "a non-1 LENSES_PARALLEL value took the parallel path: $(seq_order)"

# ============================================================================
# 6. LENSES_PARALLEL=0 reproduces the call order this replaced
# ============================================================================
setup_repo src/middleware.ts prisma/schema.prisma
OUT=$(run LENSES_PARALLEL=0 V_REVIEW=BLOCK V_SECURITY=BLOCK V_REFUTE=BLOCK)
EXPECT='review-run.txt fix-run.txt review2-run.txt security-review-run.txt security-fix-run.txt security-review2-run.txt refute-review-run.txt refute-fix-run.txt refute-review2-run.txt'
[ "$(calls | paste -sd' ' -)" = "$EXPECT" ] \
  && ok || bad "sequential mode did not reproduce the old call order: $(calls | paste -sd, -)"
# And sequentially nothing overlaps: every call ends before the next begins.
[ "$(awk 'NR<=2{print $2}' "$T/cc.log" | paste -sd, -)" = "start,end" ] \
  && ok || bad "sequential mode overlapped calls: $(seq_order)"
# A general BLOCK sequentially never buys the other two lenses — that was the
# saving the old order had, and the rollback path must still have it.
OUT=$(run LENSES_PARALLEL=0 V_REVIEW=BLOCK V2_REVIEW=BLOCK)
grep -q '^REVIEW_BLOCKED' <<<"$OUT" \
  && ok || bad "sequential: a general lens that still refuses must terminate REVIEW_BLOCKED (got: $OUT)"
grep -q 'security-review-run.txt' <<<"$(calls)" \
  && bad "sequential: a general BLOCK bought the security lens anyway: $(calls | paste -sd, -)" || ok

# ============================================================================
# 7. BOX-SIDE TEST SELECTION, driven through the production HARNESS_SUITE_RUN
# ============================================================================
# The suite the harness runs ITSELF is the reviewer's ground truth, so the seam
# that decides WHICH tests it runs is driven here rather than read. Every row
# goes through the real merged fix round: a docs-only diff buys one lens, a
# BLOCK from it buys the fix round, and that round calls
# `HARNESS_SUITE_RUN harness-suite-fix.txt fix` — the production call site. What
# the rows pin is the record the function leaves behind: the mode header on the
# outfile, the same mode in pipeline.log, the selector's own answer kept on
# disk, the argv the runner actually received, and the runner's real exit code.
mkdir -p "$T/bin/lib"
# The selector, in the shapes its contract allows (rc 0 + a list, rc 2 + a
# FULL: reason). It records that it was CALLED, so "never invoked" is a fact
# here and not an inference from a missing output file.
cat > "$T/bin/lib/test-select.sh" <<EOF
#!/bin/bash
: > "$T/sel.called"
cat "$T/sel.out"
cat "$T/sel.err" >&2
exit "\$(cat "$T/sel.rc")"
EOF
chmod +x "$T/bin/lib/test-select.sh"
sel() { # sel <rc> <stdout-line> <stderr-line>   — '' for an empty stream
  printf '%s' "$1" > "$T/sel.rc"
  : > "$T/sel.out"; [ -n "$2" ] && printf '%s\n' "$2" > "$T/sel.out"
  : > "$T/sel.err"; [ -n "$3" ] && printf '%s\n' "$3" > "$T/sel.err"
  return 0
}
# The repo the rows build in: a docs diff (one lens) plus a package.json whose
# `test` script is a shell stub that writes its own argv to $SUITE_LOG. Nothing
# is installed and no node process runs, so what is measured is npm's argument
# handling and this block's, which is exactly what the seam depends on.
setup_select_repo() {
  setup_repo docs/notes.md
  ( cd "$REPO" || exit 1
    cat > package.json <<'JSON'
{"name":"fx","version":"0.0.0","scripts":{"test":"sh -c 'echo \"argc=$#\" >> \"$SUITE_LOG\"; for a in \"$@\"; do echo \"arg=$a\" >> \"$SUITE_LOG\"; done; exit \"${STUB_RC:-0}\"' _"}}
JSON
    git add package.json
    git -c commit.gpgsign=false commit -qm 'fixture: a test script that records its own argv' ) >/dev/null 2>&1
}
# LENSES_PARALLEL=1 explicitly, as sections 1-4 do: the stubbed reviewer writes
# the merged verdict file only when it is told the parallel path is running, so
# leaving it unset would have the stub answer in the sequential shape while the
# block reads for the merged one — a fixture mismatch, not a finding.
sel_run() { # sel_run <env assignments...> -> the final RESULT (or "none")
  : > "$T/suite.log"; rm -f "$T/sel.called"
  run LENSES_PARALLEL=1 V_REVIEW=BLOCK SUITE_LOG="$T/suite.log" "$@"
}
setup_select_repo
F="$T/build/harness-suite-fix.txt"; PL="$T/build/pipeline.log"

# 7a. rc 0 with a list: the run narrows, and both records say the same thing.
sel 0 tests/x.test.ts ''
OUT=$(sel_run TEST_SELECT_EFFECTIVE=1)
[ "$(head -1 "$F" 2>/dev/null)" = 'HARNESS_SUITE: selected 1 of the suite — npm run test' ] \
  && ok || bad "a selected run must head its outfile with the mode and the script (got: $(head -1 "$F" 2>/dev/null))"
grep -qx 'argc=1' "$T/suite.log" \
  && ok || bad "the runner got the wrong argument count for a one-file selection: $(cat "$T/suite.log")"
grep -qx 'arg=tests/x.test.ts' "$T/suite.log" \
  && ok || bad "the selected path never reached the runner: $(cat "$T/suite.log")"
grep -qF 'HARNESS-VERIFY fix (npm run test) selected 1 of the suite' "$PL" \
  && ok || bad "pipeline.log does not carry the fix phase's mode line: $(grep HARNESS-VERIFY "$PL" 2>/dev/null)"
grep -Eq 'STAGE-TIMING suite-fix start=[0-9]+ end=[0-9]+ secs=[0-9]+' "$PL" \
  && ok || bad "the post-fix suite run left no STAGE-TIMING suite-fix line: $(grep STAGE-TIMING "$PL" 2>/dev/null)"
[ "$(cat "$T/build/test-select-fix.txt" 2>/dev/null)" = tests/x.test.ts ] \
  && ok || bad "the selector's own answer was not kept for the reviewer (got: $(cat "$T/build/test-select-fix.txt" 2>/dev/null))"
[ "$(tail -1 "$F" 2>/dev/null)" = 'HARNESS_EXIT: 0' ] \
  && ok || bad "HARNESS_EXIT is not the last line of a selected run (got: $(tail -1 "$F" 2>/dev/null))"
[ "$OUT" = none ] && ok || bad "a green selected suite must not terminate the build (got: $OUT)"

# 7b. The selector declines. A degraded run must never read as a selected one,
# so the reason it gave rides in the mode string and the suite runs whole.
sel 2 '' 'FULL: unmappable change src/z.ts'
OUT=$(sel_run TEST_SELECT_EFFECTIVE=1)
[ "$(head -1 "$F" 2>/dev/null)" = 'HARNESS_SUITE: full (FULL: unmappable change src/z.ts) — npm run test' ] \
  && ok || bad "a declined selection must say full and why (got: $(head -1 "$F" 2>/dev/null))"
grep -qx 'argc=0' "$T/suite.log" \
  && ok || bad "a declined selection must run the suite bare: $(cat "$T/suite.log")"
grep -q '^arg=' "$T/suite.log" \
  && bad "a declined selection passed file arguments anyway: $(cat "$T/suite.log")" || ok
[ "$(head -1 "$T/build/test-select-fix.err" 2>/dev/null)" = 'FULL: unmappable change src/z.ts' ] \
  && ok || bad "the selector's stderr was not kept (got: $(head -1 "$T/build/test-select-fix.err" 2>/dev/null))"
[ ! -s "$T/build/test-select-fix.txt" ] \
  && ok || bad "a declining selector left a non-empty list: $(cat "$T/build/test-select-fix.txt" 2>/dev/null)"
grep -qF 'HARNESS-VERIFY fix (npm run test) full (FULL: unmappable change src/z.ts)' "$PL" \
  && ok || bad "pipeline.log does not carry the degraded mode: $(grep HARNESS-VERIFY "$PL" 2>/dev/null)"

# 7c. The knob OFF, with a selector that WOULD have selected. Off means the
# selector is not consulted at all — not consulted and ignored.
sel 0 tests/x.test.ts ''
OUT=$(sel_run TEST_SELECT_EFFECTIVE=0)
[ "$(head -1 "$F" 2>/dev/null)" = 'HARNESS_SUITE: full (TEST_SELECT=0) — npm run test' ] \
  && ok || bad "with the knob off the mode must name the knob (got: $(head -1 "$F" 2>/dev/null))"
[ ! -e "$T/sel.called" ] \
  && ok || bad "the selector was invoked with TEST_SELECT_EFFECTIVE=0"
[ ! -e "$T/build/test-select-fix.txt" ] \
  && ok || bad "the knob is off and a selection file was written anyway"
grep -qx 'argc=0' "$T/suite.log" \
  && ok || bad "with the knob off the suite must run bare: $(cat "$T/suite.log")"

# 7d. A selected path containing a space is ONE argument, not two. The list is
# read with mapfile, so one line is one argv entry all the way to the runner.
sel 0 'tests/my suite.test.ts' ''
OUT=$(sel_run TEST_SELECT_EFFECTIVE=1)
grep -qx 'argc=1' "$T/suite.log" \
  && ok || bad "a path with a space did not reach the runner as one argument: $(cat "$T/suite.log")"
grep -qxF 'arg=tests/my suite.test.ts' "$T/suite.log" \
  && ok || bad "the spaced path arrived mangled: $(cat "$T/suite.log")"
[ "$(head -1 "$F" 2>/dev/null)" = 'HARNESS_SUITE: selected 1 of the suite — npm run test' ] \
  && ok || bad "a spaced path must still count as one selected file (got: $(head -1 "$F" 2>/dev/null))"

# 7e. The runner's REAL exit code, written once and after the run. A red suite
# is evidence the reviewer reads, never a reason this block stops.
sel 0 tests/x.test.ts ''
OUT=$(sel_run TEST_SELECT_EFFECTIVE=1 STUB_RC=3)
[ "$(tail -1 "$F" 2>/dev/null)" = 'HARNESS_EXIT: 3' ] \
  && ok || bad "a suite that exited 3 was not recorded as 3 (got: $(tail -1 "$F" 2>/dev/null))"
[ "$(grep -c '^HARNESS_EXIT:' "$F")" = 1 ] \
  && ok || bad "HARNESS_EXIT was written more than once (pre-stamped?): $(grep -n '^HARNESS_EXIT:' "$F")"
[ "$OUT" = none ] && ok || bad "a red suite must not terminate the build here (got: $OUT)"

# ============================================================================
# 8. A LENS DEFERRED ON A DAY BUDGET CAP DEFERS THE BUILD (BH-4489)
# ============================================================================
# The lens runs in a background subshell, so the real CC()'s `exit 3` ends only
# that subshell and its RESULT is the parent's to overwrite. The parent must
# read the BUDGET_DEFER marker after the join and defer: never buy the merged
# fix round on a missing verdict, never write a lens BLOCK for a cap or an outage.
python3 - "$RB_ALL" "$T/real-cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write("REAL_" + src[start:end])
PY
grep -q '^REAL_CC() ' "$T/real-cc.sh" && ok || bad "could not extract CC() from bin/run-build.sh"
cat > "$T/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$AC_LINE" > "$5"
exit 74
EOF
chmod +x "$T/bin/agent-call.sh"
setup_repo src/middleware.ts prisma/schema.prisma
for LINE in "budget-cap-unreadable review budget-total-unreadable:project-day" \
            "budget-stage-day review project=p stage=review usd=3/2 calls=1/-"; do
  OUT=$(run LENSES_PARALLEL=1 DEFER_LENS=security-review-run.txt AC_LINE="AGENT_CALL_REFUSED $LINE")
  [ "$OUT" = "BUILD_DEFERRED $LINE" ] && ok || bad "8 a lens deferred on '$LINE' must defer the build (got: $OUT)"
  [ "$(head -1 "$T/build/BUDGET_DEFER" 2>/dev/null)" = "$LINE" ] && ok || bad "8 no BUDGET_DEFER marker: $(cat "$T/build/BUDGET_DEFER" 2>/dev/null)"
  grep -q 'fix-run.txt\|review2-run.txt' <<<"$(calls)" \
    && bad "8 a fix round / re-review was bought on a deferred lens: $(calls | paste -sd, -)" || ok
  [ "$(calls | wc -l | tr -d ' ')" = 3 ] && ok || bad "8 expected the three lens calls only, got: $(calls | paste -sd, -)"
done
# Non-vacuity: a 74 that is NOT a budget deferral stays a lens with no verdict,
# so the merged fix round is still bought and nothing defers.
OUT=$(run LENSES_PARALLEL=1 DEFER_LENS=security-review-run.txt AC_LINE="AGENT_CALL_REFUSED llm-gate usd-cap-day lane")
[ -e "$T/build/BUDGET_DEFER" ] && bad "8 an llm-gate refusal wrote BUDGET_DEFER" || ok
calls | grep -qx fix-run.txt && ok || bad "8 non-vacuity: a lens with no verdict must still buy the merged fix round (calls: $(calls | paste -sd, -))"
case "$OUT" in BUILD_DEFERRED*) bad "8 an llm-gate refusal deferred the build: $OUT" ;; *) ok ;; esac

echo "parallel-lenses-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

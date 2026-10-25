#!/bin/bash
# tests/review-tier-test.sh — review depth is bought per risk tier (BH-485).
#
# WHAT CHANGED, and therefore what has to be pinned here. Review depth used to
# come from two file-name greps: `security` when a risky name appeared,
# `refute` when a schema/money name did, every lens on the same model with the
# same prompt and unlimited fix rounds. Now bin/lib/review-tier.sh classifies
# the diff FIRST — T0 docs/tests/config, T1 product code, T2 risky — and the
# tier decides the lens set, the review model, the prompt variant and how many
# fix rounds the build may buy.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q REVIEW-TIER bin/run-build.sh` passes just
# as happily on a build that computes a tier and then launches three lenses
# anyway, on one that logs T0 and buys the fix round regardless, and on one
# whose classifier calls a migration "docs only". What is under test is the
# behaviour: which lenses were CALLED, on which MODEL, with which PROMPT, which
# fix rounds were bought, and what landed in pipeline.log / review-tier.txt.
# Sections B-F drive the `# >>> review lenses` block extracted VERBATIM from
# bin/run-build.sh, so a regression in the shipped lines fails here.
#
# THE CLASSIFIER GATES WHAT REACHES A MERGE, so its negatives carry the weight:
# a .sql under tests/, a migration beside a README, an unreadable diff and a
# path with `..` must every one of them land on T2, never on the cheap tier.
#
# No network, no model call, no secrets. Everything runs against mktemp -d git
# repos with a stubbed reviewer.
# Run from anywhere: tests/review-tier-test.sh   (exit 0 = all pass)
set -uo pipefail
# The scratch lib when the repo has one; its own mktemp -d tree when it does not
# (tests/lib/scratch.sh does not exist in this checkout). Either way nothing
# outside $T is ever removed.
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin/lib" "$T/fakebin" "$T/logs" "$T/repos"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# TEST-CHANGE (BH-7970): the driven review/plan code sources $HARNESS/bin/lib/stage-prompt.sh and renders prompts/stages/*.md; the scratch harness carries both, as a synced box does.
scratch_install_closure bin/lib/stage-prompt.sh "$T" >/dev/null || bad "could not install bin/lib/stage-prompt.sh into the scratch harness"
mkdir -p "$T/prompts/stages"; cp "$DIR"/prompts/stages/*.md "$T/prompts/stages/"

LIB="$DIR/bin/lib/review-tier.sh"
[ -r "$LIB" ] && ok || bad "bin/lib/review-tier.sh is missing — the classifier this whole suite drives does not exist"

mkrepo() { # mkrepo <name> <changed-file>...  -> prints the repo path
  local name="$1"; shift
  local r="$T/repos/$name"
  mkdir -p "$r"
  ( cd "$r" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo base > BASE.txt
    git add -A; git -c commit.gpgsign=false commit -qm base
    git checkout -q -b feat
    for f in "$@"; do mkdir -p "$(dirname "$f")"; echo x >> "$f"; done
    git add -A; git -c commit.gpgsign=false commit -qm work ) >/dev/null 2>&1
  printf '%s' "$r"
}

# ============================================================================
# A. THE CLASSIFIER TABLE — bin/lib/review-tier.sh as the CLI the ticket names
# ============================================================================
tier_of() { ( cd "$1" && bash "$LIB" main HEAD 2>/dev/null ); }

tcase() { # tcase <expected> <name> <changed-file>...
  local want="$1" name="$2"; shift 2
  local r out got reason
  r=$(mkrepo "$name" "$@")
  out=$(tier_of "$r")
  got=${out%% *}
  [ "$got" = "$want" ] && ok || bad "A/$name ($*) classified '${got:-<nothing>}', expected $want — line: ${out:-<empty>}"
  # The reason rides in pipeline.log and in a markdown table cell: one line,
  # no control characters, bounded.
  reason=${out#*reason=}
  [ -n "$reason" ] && [ "$reason" != "$out" ] \
    && ok || bad "A/$name printed no reason= field: ${out:-<empty>}"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] \
    && ok || bad "A/$name printed more than one line: $out"
  [ "${#reason}" -le 200 ] && ok || bad "A/$name reason is ${#reason} chars, over the 200 bound"
  grep -q '[[:cntrl:]]' <<<"$(printf '%s' "$reason")" \
    && bad "A/$name reason carries a control character: $reason" || ok
}

# --- the three rows of the tier table ---------------------------------------
tcase T0 docs-only            docs/notes.md README.md
tcase T0 github-config        .github/workflows/harness-ci.yml
tcase T1 product-code         bin/evidence-summary.sh
tcase T2 migration-only       prisma/migrations/20260917_add_x.sql
tcase T2 schema-only          prisma/schema.prisma

# --- the ticket's own edge: a doc and a migration, highest wins --------------
tcase T2 doc-plus-migration   README.md prisma/migrations/20260917_add_x.sql

# --- the negatives. None of these may EVER buy the cheap tier ---------------
# A .sql fixture sitting under tests/ satisfies the T0 path list literally.
tcase T2 sql-fixture-in-tests tests/fixtures/seed.sql
# A risky product path next to a doc is still a risky diff.
tcase T2 doc-plus-auth-lib    docs/AUTH.md bin/lib/gh-app-auth.sh
tcase T2 money-path           src/lib/stripe-webhook.ts
# ...but a tests/ path whose NAME today's RISKY regex matches is T0: the tier is
# what decides depth now, and a test file is a test file.
tcase T0 tests-named-token    tests/gh-token-test.sh

# --- diffs the classifier cannot read. Both answer T2, neither crashes ------
RNODIFF=$(mkrepo nodiff docs/x.md)
OUT=$( cd "$RNODIFF" && bash "$LIB" no-such-base HEAD 2>/dev/null )
RC=$?
[ "$OUT" = "T2 reason=diff-unavailable" ] \
  && ok || bad "A/unreadable-base must be T2 diff-unavailable, got: ${OUT:-<empty>}"
[ "$RC" = 0 ] && ok || bad "A/unreadable-base exited $RC — a classification never exits nonzero"

# A path with `..` is never normalised into a tier. git diff will not print one,
# so the file list is fed in directly: the lib is sourced and git stubbed.
OUT=$( cd "$RNODIFF" && bash -c '
  . "$1" 2>/dev/null
  git() { printf "tests/../bin/run-build.sh\n"; }
  review_tier main HEAD' _ "$LIB" 2>/dev/null )
[ "$OUT" = "T2 reason=unresolvable path(s)" ] \
  && ok || bad "A/dot-dot-path must be T2 unresolvable, got: ${OUT:-<empty>}"
# The same seam proves the empty list is not read as "nothing risky changed".
OUT=$( cd "$RNODIFF" && bash -c '
  . "$1" 2>/dev/null
  git() { printf "\n"; }
  review_tier main HEAD' _ "$LIB" 2>/dev/null )
[ "$OUT" = "T2 reason=diff-unavailable" ] \
  && ok || bad "A/empty-file-list must be T2 diff-unavailable, got: ${OUT:-<empty>}"

# --- the risky-file list is NOT redefined here -------------------------------
# The lib carries a copy of the two regexes bin/run-build.sh greps with. If they
# drift, a webhook change tiers as ordinary product code. Both extractions must
# find something: an empty match on either side fails, never passes.
rb_re() { grep -m1 "^$1=" "$RB_ALL" | grep -oE "grep -icE '[^']+'" | sed "s/^grep -icE '//; s/'\$//"; }
lib_re() { grep -m1 "^$1=" "$LIB" | sed "s/^$1='//; s/'\$//"; }
for PAIR in RISKY:RT_RISKY_RE HIGHRISK:RT_HIGHRISK_RE; do
  A=$(rb_re "${PAIR%%:*}"); B=$(lib_re "${PAIR##*:}")
  [ -n "$A" ] && [ -n "$B" ] \
    && ok || bad "A/regex-sync: could not read ${PAIR%%:*} from bin/run-build.sh or ${PAIR##*:} from the lib (got '$A' vs '$B')"
  [ "$A" = "$B" ] \
    && ok || bad "A/regex-sync: ${PAIR##*:} has drifted from bin/run-build.sh's ${PAIR%%:*}
    run-build: $A
    lib:       $B"
done

# ============================================================================
# THE DRIVER — the real `# >>> review lenses` block, with a stubbed reviewer
# ============================================================================
awk '/^# >>> review lenses/{f=1;next} /^# <<< review lenses/{exit} f' \
  "$RB_ALL" > "$T/lenses.sh"
[ -s "$T/lenses.sh" ] && ok || bad "could not extract the review-lens block from bin/run-build.sh — markers missing?"

# The block runs the repo's own suite through HARNESS_SUITE_RUN, which lives in
# its own marked block and calls the stage timers. Both come out of the driver
# VERBATIM, like the lens block itself — a stub would let the real function
# break while this suite stayed green, and leaving them out would make section H
# read a command-not-found as "a T0 build skipped the suite".
awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' \
  "$RB_ALL" > "$T/timing.sh"
[ -s "$T/timing.sh" ] && ok || bad "could not extract the stage-timing block — markers missing?"
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' \
  "$RB_ALL" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

# The block reaches for these three. findings-log.sh may never fail a build;
# npm stands in for the repo suite the harness runs itself.
printf '#!/bin/bash\nexit 0\n' > "$T/bin/findings-log.sh"; chmod +x "$T/bin/findings-log.sh"
cp "$LIB" "$T/bin/lib/review-tier.sh" 2>/dev/null; chmod +x "$T/bin/lib/review-tier.sh" 2>/dev/null
printf '#!/bin/sh\necho "stub npm $*"\nexit 0\n' > "$T/fakebin/npm"; chmod +x "$T/fakebin/npm"

REPO=""
run() { # run <env assignments...>  — REPO and optionally PRESEED must be set
  rm -rf "$T/build"; mkdir -p "$T/build"
  : > "$T/cc.log"; : > "$T/review-prompt.txt"
  local s
  for s in ${PRESEED:-}; do printf 'a fix round from an earlier attempt\n' > "$T/build/$s"; done
  ( cd "$REPO" || exit 1
    env HARNESS="$T" BUILD="$T/build" PROJECT=p KEY=K BASE=main BRANCH=feat \
        PATH="$T/fakebin:$PATH" \
        REVIEW_MODEL=rm FIX_MODEL=fm \
        CCLOG="$T/cc.log" REVPROMPT="$T/review-prompt.txt" \
        REOPEN_HOT=0 REOPEN_NOTE="" KIND_SKIP_SECLENS=0 REOPEN_EXTRA_LENS=0 \
        GATES_NOTE="" SPEC_DIR=.harness/specs \
        V_REVIEW=APPROVE V_SECURITY=APPROVE V_REFUTE=APPROVE \
        V2_REVIEW=APPROVE V2_SECURITY=APPROVE V2_REFUTE=APPROVE \
        "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      BB() { :; }
      PUSH_BRANCH() { :; }
      # The stubbed agent. It records the artifact it was asked to write, the
      # MODEL it was called on, and whether the tier had already been RECORDED
      # when it was called — the ordering property, without a clock.
      CC() {
        local stage="$1" model="$2" out="$4" prompt="$5" base seen=no
        base=$(basename "$out")
        [ -s "$BUILD/review-tier.txt" ] && seen=yes
        printf "%s %s %s tier:%s\n" "start" "$base" "$model" "$seen" >> "$CCLOG"
        case "$base" in
          review-run.txt)
            printf "%s" "$prompt" > "$REVPROMPT"
            [ "$V_REVIEW"   = none ] || printf "finding\nTIER: 1\nVERDICT: %s\n" "$V_REVIEW"   > "$BUILD/review.md" ;;
          security-review-run.txt)
            [ "$V_SECURITY" = none ] || printf "finding\nVERDICT: %s\n" "$V_SECURITY" > "$BUILD/security-review.md" ;;
          refute-review-run.txt)
            [ "$V_REFUTE"   = none ] || printf "finding\nVERDICT: %s\n" "$V_REFUTE"   > "$BUILD/refute-review.md" ;;
          review2-run.txt)
            if [ "${LENSES_PARALLEL:-1}" != 1 ]; then
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
      }
      . "$1"
      . "$2"
      . "$0"
    ' "$T/lenses.sh" "$T/timing.sh" "$T/suite-run.sh" >/dev/null 2>&1 )
  cat "$T/build/RESULT" 2>/dev/null || echo none
}
calls()     { awk '{print $2}' "$T/cc.log"; }
model_of()  { awk -v a="$1" '$2==a{print $3}' "$T/cc.log"; }
plog()      { cat "$T/build/pipeline.log" 2>/dev/null; }

# ============================================================================
# B. THE WIRED BLOCK — the tier decides which lenses are actually CALLED
# ============================================================================
# T0. Today's RISKY regex matches `tests/gh-token-test.sh` on the word token, so
# before this ticket this diff bought TWO lenses. It buys one now.
REPO=$(mkrepo b-t0 tests/gh-token-test.sh docs/notes.md); PRESEED=
OUT=$(run)
[ "$OUT" = none ] && ok || bad "B/T0: three APPROVEs must not terminate the build (got: $OUT)"
[ "$(calls | grep -c .)" = 1 ] \
  && ok || bad "B/T0 must buy exactly ONE lens, got: $(calls | paste -sd, -)"
calls | grep -qx review-run.txt \
  && ok || bad "B/T0's one lens must be the general review, got: $(calls | paste -sd, -)"

# T1. Product code with no risky names — today's set, which is the general lens.
REPO=$(mkrepo b-t1 src/app/page.tsx)
OUT=$(run)
[ "$(calls | paste -sd, -)" = "review-run.txt" ] \
  && ok || bad "B/T1 must buy the general lens only, got: $(calls | paste -sd, -)"

# T2, risky but not money: review + security, exactly as main does it.
REPO=$(mkrepo b-t2-risky src/middleware.ts)
OUT=$(run)
[ "$(calls | grep -c .)" = 2 ] \
  && ok || bad "B/T2-risky must buy two lenses, got: $(calls | paste -sd, -)"
calls | grep -qx security-review-run.txt \
  && ok || bad "B/T2-risky did not buy the security lens: $(calls | paste -sd, -)"
grep -qx refute-review-run.txt <<<"$(calls)" \
  && bad "B/T2-risky bought the refuter on a diff with no schema or money file" || ok

# T2, schema: all three, unchanged.
REPO=$(mkrepo b-t2-schema prisma/schema.prisma src/middleware.ts)
OUT=$(run)
[ "$(calls | grep -c .)" = 3 ] \
  && ok || bad "B/T2-schema must buy all three lenses, got: $(calls | paste -sd, -)"

# ============================================================================
# C. THE T0 PROMPT VARIANT — the three eval cases for "static review, no build"
# ============================================================================
REPO=$(mkrepo c-t0 docs/notes.md)
OUT=$(run)
grep -q 'STATIC REVIEW, NO BUILD RUN' "$T/review-prompt.txt" \
  && ok || bad "C1: the T0 review prompt does not carry the static-review variant"
tail -c 400 "$T/review-prompt.txt" | grep -q 'VERDICT: APPROVE or VERDICT: BLOCK' \
  && ok || bad "C2: the T0 prompt lost the VERDICT contract — the variant rewrote the prompt instead of prepending to it"
grep -q 'FRAUD CLASSES' "$T/review-prompt.txt" \
  && ok || bad "C2: the T0 prompt lost the fraud-class block"
grep -q "TIER: 1" "$T/review-prompt.txt" \
  && ok || bad "C2: the T0 prompt lost the merge-tier contract"

REPO=$(mkrepo c-t1 src/app/page.tsx)
OUT=$(run)
grep -q 'STATIC REVIEW, NO BUILD RUN' "$T/review-prompt.txt" \
  && bad "C3: a T1 diff was handed the T0 static-review paragraph" || ok
grep -qi 'no application build or deployment was run' "$T/review-prompt.txt" \
  && bad "C3: a T1 prompt claims no build ran" || ok

# ============================================================================
# D. THE MODEL TIER — resolved from env, never a hardcoded model string
# ============================================================================
REPO=$(mkrepo d-t0 docs/notes.md)
OUT=$(run REVIEW_MODEL=big REVIEW_MODEL_T0=small)
[ "$(model_of review-run.txt)" = small ] \
  && ok || bad "D: a T0 lens must run on REVIEW_MODEL_T0, got: $(model_of review-run.txt)"
REPO=$(mkrepo d-t1 src/app/page.tsx)
OUT=$(run REVIEW_MODEL=big REVIEW_MODEL_T0=small)
[ "$(model_of review-run.txt)" = big ] \
  && ok || bad "D: a T1 lens must run on REVIEW_MODEL, got: $(model_of review-run.txt)"
# Unset, the knob is inert: every tier runs exactly where it ran before.
REPO=$(mkrepo d-inert docs/notes.md)
OUT=$(run REVIEW_MODEL=big)
[ "$(model_of review-run.txt)" = big ] \
  && ok || bad "D: with REVIEW_MODEL_T0 unset a T0 lens must still run on REVIEW_MODEL, got: $(model_of review-run.txt)"
# And no model id was hardcoded to get there.
grep -qE 'claude-(opus|sonnet|haiku|fable)' "$LIB" \
  && bad "D: bin/lib/review-tier.sh hardcodes a claude-* model string" || ok

# ============================================================================
# E. FIX-ROUND CAPS — a tier that has spent its rounds buys no more
# ============================================================================
# (i) T0, cap 1, one round already on disk, and a lens that refuses.
REPO=$(mkrepo e-t0 docs/notes.md); PRESEED="fix-run.txt"
OUT=$(run V_REVIEW=BLOCK)
grep -q '^REVIEW_BLOCKED' <<<"$OUT" \
  && ok || bad "E(i): a capped T0 whose lens refuses must terminate REVIEW_BLOCKED (got: $OUT)"
grep -qx fix-run.txt <<<"$(calls)" \
  && bad "E(i): the capped T0 bought a fix round anyway: $(calls | paste -sd, -)" || ok
plog | grep -q 'FIX-ROUND CAP 1 reached at tier T0' \
  && ok || bad "E(i): pipeline.log does not record the cap that was hit: $(plog | paste -sd' / ' -)"

# (ii) the same shape at T2 — uncapped, so the round IS bought and the build
#      goes on. This is the case that proves the cap is a cap and not a delete.
REPO=$(mkrepo e-t2 prisma/schema.prisma); PRESEED="fix-run.txt"
OUT=$(run V_REVIEW=BLOCK)
calls | grep -qx fix-run.txt \
  && ok || bad "E(ii): T2 must still buy its fix round with rounds already on disk: $(calls | paste -sd, -)"
[ "$OUT" = none ] \
  && ok || bad "E(ii): the T2 build terminated instead of proceeding after its fix round (got: $OUT)"
grep -q 'FIX-ROUND CAP' <<<"$(plog)" \
  && bad "E(iii): an uncapped T2 logged a cap line" || ok

# (iii) T1, cap 2: one round spent still buys a round, two does not.
REPO=$(mkrepo e-t1 src/app/page.tsx); PRESEED="fix-run.txt"
OUT=$(run V_REVIEW=BLOCK)
calls | grep -qx fix-run.txt \
  && ok || bad "E(iv): T1 with one round spent must still buy the second: $(calls | paste -sd, -)"
PRESEED="fix-run.txt security-fix-run.txt"
OUT=$(run V_REVIEW=BLOCK)
grep -qx fix-run.txt <<<"$(calls)" \
  && bad "E(v): T1 bought a third fix round past its cap of 2: $(calls | paste -sd, -)" || ok
plog | grep -q 'FIX-ROUND CAP 2 reached at tier T1' \
  && ok || bad "E(v): T1's cap was not recorded: $(plog | paste -sd' / ' -)"
# qa-fix-run.txt is a different stage and is deliberately NOT counted here.
PRESEED="fix-run.txt qa-fix-run.txt"
OUT=$(run V_REVIEW=BLOCK)
calls | grep -qx fix-run.txt \
  && ok || bad "E(vi): a QA fix round was counted against the lens cap: $(calls | paste -sd, -)"

# The sequential rollback path is guarded too — it buys a round PER LENS, which
# is the path where a cap of 1 or 2 actually binds on a first run.
REPO=$(mkrepo e-seq docs/notes.md); PRESEED="fix-run.txt"
OUT=$(run LENSES_PARALLEL=0 V_REVIEW=BLOCK)
grep -q '^REVIEW_BLOCKED' <<<"$OUT" \
  && ok || bad "E(vii): sequential T0 past its cap must terminate REVIEW_BLOCKED (got: $OUT)"
grep -qx fix-run.txt <<<"$(calls)" \
  && bad "E(vii): sequential mode bought a fix round past the cap: $(calls | paste -sd, -)" || ok
PRESEED=

# ============================================================================
# F. THE RECORDS — pipeline.log and review-tier.txt, written BEFORE any lens
# ============================================================================
for ROW in t0:docs/notes.md t1:src/app/page.tsx t2:prisma/schema.prisma; do
  WANT=$(printf '%s' "${ROW%%:*}" | tr '[:lower:]' '[:upper:]')
  REPO=$(mkrepo "f-${ROW%%:*}" "${ROW##*:}")
  OUT=$(run)
  plog | grep -qE "REVIEW-TIER $WANT reason=.+ lenses=.+ cap=[0-9]+" \
    && ok || bad "F/$WANT: pipeline.log has no REVIEW-TIER line: $(plog | grep REVIEW-TIER || echo '<none>')"
  grep -q "REVIEW-TIER $WANT reason=" "$T/build/review-tier.txt" 2>/dev/null \
    && ok || bad "F/$WANT: review-tier.txt does not hold the tier: $(cat "$T/build/review-tier.txt" 2>/dev/null)"
  # Every lens call saw the record already on disk — the tier cannot be
  # decided after a lens has read the diff at some other depth.
  [ "$(awk '{print $4}' "$T/cc.log" | sort -u)" = "tier:yes" ] \
    && ok || bad "F/$WANT: a lens ran before the tier was recorded: $(cat "$T/cc.log")"
done

# ============================================================================
# G. THE EVIDENCE ROW — the tier reaches the PR body, and only as a row
# ============================================================================
EV="$DIR/bin/evidence-summary.sh"
GB="$T/rec-tier"; mkdir -p "$GB"
printf 'suite\nHARNESS_EXIT: 0\n' > "$GB/harness-suite.txt"
printf 'REVIEW-TIER T0 reason=docs/tests/config only (2 paths) lenses=review cap=1\n' > "$GB/review-tier.txt"
GOUT=$("$EV" "$GB" 1 "" settled)
grep -q '| review depth | T0 — docs/tests/config only (2 paths) (lenses: review, fix-round cap 1) |' <<<"$GOUT" \
  && ok || bad "G: the review-depth row is missing or malformed: $(grep 'review depth' <<<"$GOUT")"
[ "$(grep -c '^|.*|.*|.*|' <<<"$GOUT")" = 0 ] \
  && ok || bad "G: the review-depth row splits the markdown table"
rm -f "$GB/review-tier.txt"
GOUT2=$("$EV" "$GB" 1 "" settled)
grep -q 'review depth' <<<"$GOUT2" \
  && bad "G: a record with no review-tier.txt rendered a review-depth row anyway" || ok
# The digest is the artifact ref: the new row must not have been smuggled in.
[ "$(grep 'Digest:' <<<"$GOUT")" = "$(grep 'Digest:' <<<"$GOUT2")" ] \
  && ok || bad "G: the new row leaked into the digest string
    with:    $(grep 'Digest:' <<<"$GOUT")
    without: $(grep 'Digest:' <<<"$GOUT2")"
# An uncapped tier says so rather than printing "cap 0".
printf 'REVIEW-TIER T2 reason=2 risky path(s), 1 schema/money path(s) lenses=review,security,refute cap=0\n' > "$GB/review-tier.txt"
GOUT3=$("$EV" "$GB" 2 "" settled)
grep -q '| review depth | T2 — 2 risky path(s), 1 schema/money path(s) (lenses: review, security, refute, fix-round cap uncapped) |' <<<"$GOUT3" \
  && ok || bad "G: the T2 row is wrong: $(grep 'review depth' <<<"$GOUT3")"

# ============================================================================
# H. NOTHING ELSE MOVED — tiering touches the LLM lenses and nothing else
# ============================================================================
# The repo suite the harness runs ITSELF still runs at T0. That is the one piece
# of ground truth the review stage has, and a cheaper tier must not buy it away.
REPO=$(mkrepo h-t0 docs/notes.md)
printf '{"scripts":{"test":"true"}}\n' > "$REPO/package.json"
OUT=$(run)
plog | grep -q 'HARNESS-VERIFY' \
  && ok || bad "H: a T0 build skipped HARNESS-VERIFY: $(plog | paste -sd' / ' -)"
grep -q 'HARNESS_EXIT' "$T/build/harness-suite.txt" 2>/dev/null \
  && ok || bad "H: a T0 build wrote no harness-suite.txt"

# The other two terminals still exist and still fire at T2.
REPO=$(mkrepo h-sec src/middleware.ts)
OUT=$(run V_SECURITY=BLOCK V2_SECURITY=BLOCK)
grep -q '^SECURITY_BLOCKED .*security-review.md' <<<"$OUT" \
  && ok || bad "H: a refusing security lens must still terminate SECURITY_BLOCKED (got: $OUT)"
REPO=$(mkrepo h-ref prisma/schema.prisma)
OUT=$(run V_REFUTE=BLOCK V2_REFUTE=BLOCK)
grep -q '^REFUTE_BLOCKED .*refute-review.md' <<<"$OUT" \
  && ok || bad "H: a refusing refuter must still terminate REFUTE_BLOCKED (got: $OUT)"

# And a box whose bin/lib/ has not synced yet behaves exactly as it does today:
# no classifier means T2, today's lens set, uncapped rounds. Absent is never the
# cheap tier.
mv "$T/bin/lib/review-tier.sh" "$T/bin/lib/review-tier.sh.away"
REPO=$(mkrepo h-nolib tests/gh-token-test.sh); PRESEED="fix-run.txt"
OUT=$(run V_REVIEW=BLOCK)
[ "$(calls | grep -c 'review-run.txt\|security-review-run.txt')" = 2 ] \
  && ok || bad "H: with no classifier the lens set must fall back to today's two: $(calls | paste -sd, -)"
calls | grep -qx fix-run.txt \
  && ok || bad "H: with no classifier the fix round must stay uncapped: $(calls | paste -sd, -)"
grep -q 'REVIEW-TIER T2 ' "$T/build/review-tier.txt" 2>/dev/null \
  && ok || bad "H: a missing classifier must record T2, got: $(cat "$T/build/review-tier.txt" 2>/dev/null)"
mv "$T/bin/lib/review-tier.sh.away" "$T/bin/lib/review-tier.sh"
PRESEED=

echo "review-tier-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

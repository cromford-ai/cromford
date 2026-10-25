#!/bin/bash
# tests/run-build-stage-lane.bh-1872-test.sh — LENS_REFUSE reads only the
# refusing lens's OWN runner sidecars on the sequential path (BH-1872).
#
# BH-1853 had every lens's refusal also read fix-run.txt / review2-run.txt.
# Those are the ONE merged fix round and re-review on the parallel path, so
# there they speak for every lens. On the sequential path (LENSES_PARALLEL=0)
# they are the GENERAL lens's own fix round and re-review. A review fix round
# that ran out of lane, followed by a re-review that still APPROVEd, turned a
# genuine security or refute BLOCK further down the loop into BUILD_DEFERRED
# (exit 3) instead of SECURITY_BLOCKED / REFUTE_BLOCKED (exit 6).
#   K1-K3 sequential: another lens's exhausted sidecar no longer defers a BLOCK
#   K4    sequential: the lens's OWN exhausted fix round still defers
#   K5    sequential: fix-run.txt is the review lens's own, so it still defers
#   K6-K7 merged path (LENSES_PARALLEL=1 or unset): the shared pair still counts
#   K8    the real `# >>> review lenses` block, sequential, end to end
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# TEST-CHANGE (BH-7970): the driven review/plan code sources $HARNESS/bin/lib/stage-prompt.sh and renders prompts/stages/*.md; the scratch harness carries both, as a synced box does.
scratch_install_closure bin/lib/stage-prompt.sh "$T" >/dev/null || bad "could not install bin/lib/stage-prompt.sh into the scratch harness"
mkdir -p "$T/prompts/stages"; cp "$DIR"/prompts/stages/*.md "$T/prompts/stages/"

cut_block() { # cut_block <marker> <outfile>
  awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"
}
cut_fn() { # cut_fn <name> — one column-0 function out of the flattened driver
  awk -v f="$1" 'index($0, f "() {")==1{p=1} p{print} p&&/^}/{exit}' "$RB_ALL"
}
cut_block "stage lane verdict" "$T/lane.sh"
cut_block "review lenses"      "$T/lenses.sh"
cut_block "stage timing"       "$T/timing.sh"
cut_block "harness suite run"  "$T/suite-run.sh"
{ cut_fn LENS_ART; cut_fn LENS_VARS; cut_fn LENS_REFUSE; } > "$T/lens.sh"
for B in lane lenses timing suite-run lens; do
  [ -s "$T/$B.sh" ] && ok || bad "could not extract '$B' from the pipeline text"
done

EXH="RUNNER_EXHAUSTED class=account-exhausted(quota) seen=account-exhausted runner=claude rc=1 exhausted=claude resets_at=1790000000"
AUTH="RUNNER_ERROR class=auth(credential) seen=auth runner=claude rc=1"

# DRIVE <build-dir> <LENSES_PARALLEL value|unset> <script>
DRIVE() {
  local B="$1"
  ( BUILD="$B"; PROJECT=project-5; KEY=BH-1872; BASE=main; BRANCH=ticket/bh-1872
    REVIEW_MODEL=m; FIX_MODEL=m; RISKY=1; HIGHRISK=1
    if [ "$2" = unset ]; then unset LENSES_PARALLEL; else LENSES_PARALLEL="$2"; fi
    STAMP() { echo 2026-09-24T00:00:00Z; }
    RESULT() { echo "$*" > "$B/RESULT"; }
    BB() { :; }
    # shellcheck disable=SC1090
    . "$T/lane.sh"; . "$T/lens.sh"
    eval "$3" ) >/dev/null 2>&1
  echo "$? $(cat "$B/RESULT" 2>/dev/null || echo none)"
}
NB=0
fresh() { NB=$((NB+1)); B="$T/b$NB"; mkdir -p "$B"; }
cls() { printf '%s\n' "$2" > "$B/$1.class"; }  # cls <outfile-name> <line>
blk() { echo "VERDICT: BLOCK" > "$B/$1-review.md"; }

# ── K1-K3: another lens's sidecar does not defer a genuine BLOCK ──────────
fresh; blk security; cls fix-run.txt "$EXH"
OUT=$(DRIVE "$B" 0 'LENS_REFUSE security')
[ "$OUT" = "6 SECURITY_BLOCKED $B/security-review.md" ] && ok || bad "K1: a sequential security BLOCK deferred on the review lens's exhausted fix round: $OUT"
fresh; blk security; cls review2-run.txt "$EXH"
OUT=$(DRIVE "$B" 0 'LENS_REFUSE security')
[ "$OUT" = "6 SECURITY_BLOCKED $B/security-review.md" ] && ok || bad "K2: a sequential security BLOCK deferred on the review lens's exhausted re-review: $OUT"
fresh; blk refute; cls fix-run.txt "$AUTH"
OUT=$(DRIVE "$B" 0 'LENS_REFUSE refute')
[ "$OUT" = "6 REFUTE_BLOCKED $B/refute-review.md" ] && ok || bad "K3: a sequential refute BLOCK deferred on the review lens's de-authed fix round: $OUT"

# ── K4-K5: the lens's own sidecars still defer ────────────────────────────
fresh; blk security; cls security-fix-run.txt "$EXH"
OUT=$(DRIVE "$B" 0 'LENS_REFUSE security')
[ "$OUT" = "3 BUILD_DEFERRED security review session ended $EXH" ] && ok || bad "K4: security's own exhausted fix round no longer defers: $OUT"
fresh; echo "VERDICT: BLOCK" > "$B/review.md"; cls fix-run.txt "$EXH"
OUT=$(DRIVE "$B" 0 'LENS_REFUSE review')
[ "$OUT" = "3 BUILD_DEFERRED review review session ended $EXH" ] && ok || bad "K5: the review lens's own exhausted fix round no longer defers: $OUT"

# ── K6-K7: the merged path shares fix-run.txt / review2-run.txt ───────────
for LP in 1 unset; do
  fresh; blk security; cls fix-run.txt "$EXH"
  OUT=$(DRIVE "$B" "$LP" 'LENS_REFUSE security')
  [ "$OUT" = "3 BUILD_DEFERRED security review session ended $EXH" ] && ok || bad "K6 (LENSES_PARALLEL=$LP): the exhausted merged fix round did not defer security: $OUT"
done
fresh; blk refute; cls review2-run.txt "$EXH"
OUT=$(DRIVE "$B" 1 'LENS_REFUSE refute')
[ "$OUT" = "3 BUILD_DEFERRED refute review session ended $EXH" ] && ok || bad "K7: the exhausted merged re-review did not defer refute: $OUT"

# ── K8: the real review-lens block, sequential, end to end ────────────────
# The review lens BLOCKs, its fix round runs out of lane (fix-run.txt.class),
# its re-review APPROVEs; then the security lens BLOCKs and still BLOCKs after
# its own fix round. The real STAGE_LANE_DEFER is loaded, so a deferral here is
# the production one.
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/findings-log.sh"; chmod +x "$T/bin/findings-log.sh"
REPO="$T/repo"
( mkdir -p "$REPO" && cd "$REPO" || exit 1
  git init -q -b main
  git config user.email t@example.com; git config user.name tester
  echo base > README.md
  git add -A; git -c commit.gpgsign=false commit -qm base
  git checkout -q -b feat
  mkdir -p src; echo x > src/middleware.ts   # a risky file: buys the security lens
  git add -A; git -c commit.gpgsign=false commit -qm work ) >/dev/null 2>&1
mkdir -p "$T/build"
( cd "$REPO" || exit 1
  env HARNESS="$T" BUILD="$T/build" PROJECT=p KEY=K BASE=main BRANCH=feat \
      REVIEW_MODEL=rm FIX_MODEL=fm CCLOG="$T/cc.log" EXH="$EXH" LENSES_PARALLEL=0 \
      REOPEN_HOT=0 REOPEN_NOTE="" KIND_SKIP_SECLENS=0 REOPEN_EXTRA_LENS=0 \
      GATES_NOTE="" SPEC_DIR=.harness/specs \
  bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    BB() { :; }
    PUSH_BRANCH() { :; }
    CC() {
      local out="$4" base
      base=$(basename "$out")
      echo "$base" >> "$CCLOG"
      case "$base" in
        review-run.txt)           printf "finding\nTIER: 1\nVERDICT: BLOCK\n" > "$BUILD/review.md" ;;
        fix-run.txt)              printf "%s\n" "$EXH" > "$out.class" ;;
        review2-run.txt)          printf "finding2\nTIER: 1\nVERDICT: APPROVE\n" >> "$BUILD/review.md" ;;
        security-review-run.txt)  printf "finding\nVERDICT: BLOCK\n" > "$BUILD/security-review.md" ;;
        security-review2-run.txt) printf "finding2\nVERDICT: BLOCK\n" >> "$BUILD/security-review.md" ;;
      esac
    }
    . "$1"; . "$2"; . "$3"
    . "$0"
  ' "$T/lenses.sh" "$T/lane.sh" "$T/timing.sh" "$T/suite-run.sh" >/dev/null 2>&1 )
RC=$?
OUT=$(cat "$T/build/RESULT" 2>/dev/null || echo none)
grep -qx fix-run.txt "$T/cc.log" 2>/dev/null && grep -qx security-review2-run.txt "$T/cc.log" \
  && ok || bad "K8: the fixture did not reach the security re-review (calls: $(paste -sd, "$T/cc.log" 2>/dev/null))"
[ "$RC $OUT" = "6 SECURITY_BLOCKED $T/build/security-review.md" ] && ok || bad "K8: the real lens block turned a genuine security BLOCK into: rc=$RC $OUT"

echo "run-build-stage-lane.bh-1872: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
